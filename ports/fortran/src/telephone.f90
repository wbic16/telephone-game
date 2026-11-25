! telephone.f90 - Exocortical Telephone Game CLI (contract v2) for the
! Fortran libphext port. Wire protocol: one JSON request in (a single
! line), one JSON response out. With no arguments it handles a single
! request on stdin; with the argument "serve" it loops over JSON lines.
!
!   {"cmd":"id"}                          -> {"impl":"fortran"}
!   {"cmd":"echo","ping":{game,round,nonce}} -> {"impl":"fortran","echo":hex}
!   {"cmd":"elect","position":..,"candidates":[..],"turn":n} -> {"elect":id}
!   {"cmd":"choose","state":b64,"position":..,"turn":n} -> insert step
!   {"cmd":"apply","state":b64,"step":{...}} -> {"state_b64","state_sha256"}
!   {"cmd":"keygen"}                      -> {"impl":"fortran","pubkey":armored}
!   {"cmd":"attest","descriptor":{...}}   -> {"signature":armored}
!   {"cmd":"validate","state":b64,"step":{...},"prior_state":b64?}
!                                         -> {"impl","verdict","detail"}
!   {"cmd":"verify","state":b64,"pubkeys":armored}
!                                         -> {"impl","verdict","placements_checked","first_failure"}
! The state key is accepted as "state" (contract v2) or "state_b64".
!
! Echo rule (this port's idiom, deterministic given the ping):
! sha256 hex of "fortran|<game>|<round>|<nonce>".
!
! Elect rule (popcorn, this port's idiom): seed = sha256(position
! bytes || byte(turn) || candidates joined with ","); the winner is
! candidates[seed_byte0 mod count(candidates)].
!
! Choose rule (insert-only per contract v2): seed = sha256(position ||
! byte(turn) || state). First candidate = tracked position with
! component seed_byte1 mod 9 advanced by 1 + seed_byte2 mod 3
! (wrapping within 1..999); while the candidate holds a scroll in the
! given state, advance it by one scroll (lexicographic +1 within
! 999^9). The stress.phext bookkeeping coordinates 1.1.1/1.1.1/1.1.1-3
! count as always used. Text: "fortran turn <turn> at <coordinate>".
!
! Canonical JSON (attest/verify): compact, keys sorted, Python-style
! string escaping. Descriptors are flat objects by contract; the
! canonicalizer sorts the top-level pairs of a flat object and emits
! value spans verbatim (driver-produced spans are already minimally
! escaped: hex hashes, coordinates, integers).
!
! stress.phext layout (contract v2, pinned formats — the driver's
! inscription is canonical): index scroll at 1.1.1/1.1.1/1.1.1 with a
! header line, then one "<turn> <coordinate> <sha256hex> <actor id>"
! line per placement; participant public keys at 1.1.1/1.1.1/1.1.2;
! sha256 of the keys scroll text EXACTLY as inscribed (no trimming)
! at 1.1.1/1.1.1/1.1.3; event scrolls at 1.1.1/1.1.1/2.1.<seq> (seq
! from 1), each canonical JSON {"prev": <sha256 of previous event's
! body, or null>, "body": {...}}. A placement body carries type,
! turn, actor, elect_by, coord, text_sha256, file_sha256 (file hash
! after the placement insert, before inscription), att (base64 of
! the armored detached signature), echoes, consensus_prev. The
! signed attestation descriptor is the canonical JSON {"turn",
! "coordinate","scroll_sha256","file_sha256"} built from the body
! (flat, so canon_flat-style manual assembly is exact). Verify walks
! every event: chain integrity via prev (the inscribed body span is
! already canonical, so its sha256 is the chain hash), placement
! present with matching hash, index line matching (turn, hash,
! actor), signature valid against the inscribed public keys.
!
! PGP: gpg (2.4.4 on the hub), key home $TELEPHONE_GNUPG_HOME or
! ~/telephone-fortran/gnupg. Private keys never leave that home.
program telephone
  use phext_mod
  use wire_mod
  implicit none

  character(len=*), parameter :: IMPL = 'fortran'
  character(len=*), parameter :: KEY_UID = 'libphext telephone fortran'
  character(len=:), allocatable :: req, out
  integer :: ios
  logical :: serve
  character(len=32) :: arg1
  ! Serve-mode validator cache: init stores the state; a driver-form
  ! validate checks against it and advances it on pass. Mirrors
  ! harness/adapter_base.py (init_cache / validate).
  character(len=:), allocatable :: cache_state
  logical :: cache_set = .false.

  serve = .false.
  if (command_argument_count() >= 1) then
    call get_command_argument(1, arg1)
    serve = trim(arg1) == 'serve'
  end if

  allocate(character(len=67108864) :: req)
  do
    read(*, '(A)', iostat=ios) req
    if (ios /= 0 .and. len_trim(req) == 0) exit
    ! Game-scale framing (2026-11-24): lines over 8 KB may arrive
    ! gzip-framed as "GZ1:" + base64(gzip(line)) — the fleet-ssh
    ! channel is ~25-70 KB/s and raw base64 state lines took minutes
    ! at 1,000 placements. Fortran has no zlib, so (de)compression
    ! shells to the system gzip(1) on temp files. Lossless; plain
    ! lines unchanged.
    if (len_trim(req) >= 4) then
      if (req(1:4) == 'GZ1:') call gz_unframe_req()
    end if
    ! NB: never reassign req itself (allocatable assignment would
    ! shrink the buffer); pass the used slice to handle.
    out = handle(req(1:len_trim(req)))
    if (len_trim(out) > 8192) call gz_frame_out()
    write(*, '(A)') out
    if (.not. serve) exit
    if (ios /= 0) exit
  end do

contains

  subroutine gz_unframe_req()
    ! Replace the GZ1:-framed content of req with the plain line,
    ! in place (req's 64 MB allocation is preserved).
    character(len=:), allocatable :: raw, plain
    integer :: u, sz
    raw = b64_decode(req(5:len_trim(req)))
    open(newunit=u, file='/tmp/telephone-fortran-gz.bin', &
         access='stream', form='unformatted', status='replace')
    write(u) raw
    close(u)
    call execute_command_line('gzip -dc /tmp/telephone-fortran-gz.bin' // &
         ' > /tmp/telephone-fortran-gz.out')
    inquire(file='/tmp/telephone-fortran-gz.out', size=sz)
    allocate(character(len=sz) :: plain)
    open(newunit=u, file='/tmp/telephone-fortran-gz.out', &
         access='stream', form='unformatted', status='old')
    read(u) plain
    close(u)
    req(1:sz) = plain
    req(sz+1:) = ' '
    deallocate(raw, plain)
  end subroutine gz_unframe_req

  subroutine gz_frame_out()
    ! Replace out with its GZ1:-framed form.
    character(len=:), allocatable :: gz
    integer :: u, sz
    open(newunit=u, file='/tmp/telephone-fortran-gz.bin', &
         access='stream', form='unformatted', status='replace')
    write(u) out(1:len_trim(out))
    close(u)
    call execute_command_line('gzip -c /tmp/telephone-fortran-gz.bin' // &
         ' > /tmp/telephone-fortran-gz.out')
    inquire(file='/tmp/telephone-fortran-gz.out', size=sz)
    allocate(character(len=sz) :: gz)
    open(newunit=u, file='/tmp/telephone-fortran-gz.out', &
         access='stream', form='unformatted', status='old')
    read(u) gz
    close(u)
    out = 'GZ1:' // b64_encode(gz)
    deallocate(gz)
  end subroutine gz_frame_out


  function handle(req) result(out)
    character(len=*), intent(in) :: req
    character(len=:), allocatable :: out
    character(len=:), allocatable :: cmd
    logical :: found
    call json_get_string(req, 'cmd', cmd, found)
    if (.not. found) then
      out = '{"error":"missing cmd"}'
      return
    end if
    select case (cmd)
    case ('id')
      out = '{"impl":"' // IMPL // '"}'
    case ('echo')
      out = do_echo(req)
    case ('elect')
      out = do_elect(req)
    case ('choose')
      out = do_choose(req)
    case ('apply')
      out = do_apply(req)
    case ('keygen')
      out = do_keygen()
    case ('init')
      out = do_init(req)
    case ('attest')
      out = do_attest(req)
    case ('validate')
      out = do_validate(req)
    case ('verify')
      out = do_verify(req)
    case default
      out = '{"error":"unknown cmd"}'
    end select
  end function handle

  function intstr(n) result(s)
    integer, intent(in) :: n
    character(len=:), allocatable :: s
    character(len=32) :: tmp
    write(tmp, '(I0)') n
    s = trim(tmp)
  end function intstr

  integer function hv(ch)
    character, intent(in) :: ch
    if (ch >= '0' .and. ch <= '9') then
      hv = iachar(ch) - iachar('0')
    else if (ch >= 'a' .and. ch <= 'f') then
      hv = iachar(ch) - iachar('a') + 10
    else
      hv = iachar(ch) - iachar('A') + 10
    end if
  end function hv

  subroutine seed_bytes(text, b1, b2, b3)
    character(len=*), intent(in) :: text
    integer, intent(out) :: b1, b2, b3
    character(len=64) :: hex
    hex = sha256_hex(text)
    b1 = hv(hex(1:1)) * 16 + hv(hex(2:2))
    b2 = hv(hex(3:3)) * 16 + hv(hex(4:4))
    b3 = hv(hex(5:5)) * 16 + hv(hex(6:6))
  end subroutine seed_bytes

  function get_state(req) result(state)
    character(len=*), intent(in) :: req
    character(len=:), allocatable :: state
    character(len=:), allocatable :: b64
    logical :: found
    call json_get_string(req, 'state', b64, found)
    if (.not. found) call json_get_string(req, 'state_b64', b64, found)
    if (.not. found) b64 = ''
    state = b64_decode(b64)
  end function get_state

  function do_echo(req) result(out)
    character(len=*), intent(in) :: req
    character(len=:), allocatable :: out
    character(len=:), allocatable :: ping, game, nonce
    integer :: round
    logical :: found
    call json_get_object(req, 'ping', ping, found)
    if (.not. found) then
      out = '{"error":"missing ping"}'
      return
    end if
    call json_get_string(ping, 'game', game, found)
    if (.not. found) game = ''
    call json_get_string(ping, 'nonce', nonce, found)
    if (.not. found) nonce = ''
    call json_get_int(ping, 'round', round, found)
    if (.not. found) call json_get_int(ping, 'turn', round, found)
    if (.not. found) round = 0
    out = '{"impl":"' // IMPL // '","echo":"' // &
          sha256_hex(IMPL // '|' // game // '|' // intstr(round) // '|' // nonce) // '"}'
  end function do_echo

  function do_elect(req) result(out)
    character(len=*), intent(in) :: req
    character(len=:), allocatable :: out
    character(len=:), allocatable :: position, cands(:)
    character(len=:), allocatable :: joined
    integer :: turn, n, b1, b2, b3, i
    logical :: found
    call json_get_string(req, 'position', position, found)
    if (.not. found) position = ''
    call json_get_int(req, 'turn', turn, found)
    if (.not. found) turn = 0
    call json_get_string_array(req, 'candidates', cands, n, found)
    if (.not. found .or. n == 0) then
      out = '{"error":"elect: no candidates"}'
      return
    end if
    joined = ''
    do i = 1, n
      if (i > 1) joined = joined // ','
      joined = joined // trim(cands(i))
    end do
    call seed_bytes(position // achar(mod(turn, 256)) // joined, b1, b2, b3)
    out = '{"elect":"' // trim(cands(mod(b1, n) + 1)) // '"}'
  end function do_elect

  function do_choose(req) result(out)
    character(len=*), intent(in) :: req
    character(len=:), allocatable :: out
    character(len=:), allocatable :: state, position, coord_str
    integer :: turn, coord(9), b1, b2, b3, i
    logical :: found, ok
    type(scroll_t), allocatable :: scrolls(:)
    call json_get_string(req, 'position', position, found)
    call json_get_int(req, 'turn', turn, found)
    if (.not. found) turn = 0
    state = get_state(req)
    call parse_coordinate(position, coord, ok)
    if (.not. ok) then
      out = '{"error":"invalid position"}'
      return
    end if
    call seed_bytes(position // achar(mod(turn, 256)) // state, b1, b2, b3)
    coord(mod(b2, 9) + 1) = mod(coord(mod(b2, 9) + 1) - 1 + 1 + mod(b3, 3), 999) + 1
    call phokenize(state, scrolls)
    do
      if (.not. coord_used(scrolls, coord)) exit
      call next_coord(coord)
    end do
    coord_str = format_coordinate(coord)
    out = '{"op":"insert","coordinate":"' // coord_str // '","text":"' // &
          IMPL // ' turn ' // intstr(turn) // ' at ' // coord_str // '"}'
  end function do_choose

  logical function coord_used(scrolls, coord)
    type(scroll_t), intent(in) :: scrolls(:)
    integer, intent(in) :: coord(9)
    integer :: i
    coord_used = .true.
    ! Bookkeeping scrolls of stress.phext are never placements.
    if (all(coord == [1, 1, 1, 1, 1, 1, 1, 1, 1]) .or. &
        all(coord == [1, 1, 1, 1, 1, 1, 1, 1, 2]) .or. &
        all(coord == [1, 1, 1, 1, 1, 1, 1, 1, 3])) return
    do i = 1, size(scrolls)
      if (compare_coords(scrolls(i)%coord, coord) == 0) return
    end do
    coord_used = .false.
  end function coord_used

  subroutine next_coord(coord)
    integer, intent(inout) :: coord(9)
    integer :: d
    do d = 9, 1, -1
      if (coord(d) < 999) then
        coord(d) = coord(d) + 1
        return
      end if
      coord(d) = 1
    end do
  end subroutine next_coord

  subroutine apply_step(state, op, coord_str, text, new_state, fetch_hex, has_fetch)
    character(len=*), intent(in) :: state, op, coord_str, text
    character(len=:), allocatable, intent(out) :: new_state, fetch_hex
    logical, intent(out) :: has_fetch
    integer :: coord(9)
    logical :: ok
    has_fetch = .false.
    fetch_hex = ''
    new_state = state
    call parse_coordinate(coord_str, coord, ok)
    if (.not. ok) return
    select case (op)
    case ('insert')
      new_state = insert(state, coord, text)
    case ('replace')
      new_state = replace(state, coord, text)
    case ('remove')
      new_state = remove(state, coord)
    case ('fetch')
      fetch_hex = sha256_hex(fetch(state, coord))
      has_fetch = .true.
    case default
      new_state = state
    end select
  end subroutine apply_step

  subroutine get_step(req, op, coord_str, text, ok)
    character(len=*), intent(in) :: req
    character(len=:), allocatable, intent(out) :: op, coord_str, text
    logical, intent(out) :: ok
    character(len=:), allocatable :: step
    logical :: found
    call json_get_object(req, 'step', step, found)
    ok = found
    if (.not. ok) return
    call json_get_string(step, 'op', op, found)
    call json_get_string(step, 'coordinate', coord_str, found)
    call json_get_string(step, 'text', text, found)
    if (.not. found) text = ''
  end subroutine get_step

  function do_apply(req) result(out)
    character(len=*), intent(in) :: req
    character(len=:), allocatable :: out
    character(len=:), allocatable :: op, coord_str, text
    character(len=:), allocatable :: new_state, fetch_hex
    logical :: has_fetch, ok
    call get_step(req, op, coord_str, text, ok)
    if (.not. ok) then
      out = '{"error":"missing step"}'
      return
    end if
    call apply_step(get_state(req), op, coord_str, text, new_state, fetch_hex, has_fetch)
    out = '{"state_b64":"' // b64_encode(new_state) // '","state_sha256":"' // &
          sha256_hex(new_state) // '","fetch_sha256":'
    if (has_fetch) then
      out = out // '"' // fetch_hex // '"}'
    else
      out = out // 'null}'
    end if
  end function do_apply

  ! ---- file + shell helpers -------------------------------------------------

  function home_dir() result(h)
    character(len=:), allocatable :: h
    character(len=1024) :: buf
    integer :: ln, st
    call get_environment_variable('HOME', buf, ln, st)
    h = buf(1:ln)
  end function home_dir

  function gnupg_home() result(h)
    character(len=:), allocatable :: h
    character(len=1024) :: buf
    integer :: ln, st
    call get_environment_variable('TELEPHONE_GNUPG_HOME', buf, ln, st)
    if (st == 0 .and. ln > 0) then
      h = buf(1:ln)
    else
      h = home_dir() // '/telephone-' // IMPL // '/gnupg'
    end if
  end function gnupg_home

  function tmp_dir() result(d)
    character(len=:), allocatable :: d
    integer :: st
    d = home_dir() // '/telephone-' // IMPL // '/tmp'
    call execute_command_line('mkdir -p "' // d // '"', exitstat=st)
  end function tmp_dir

  subroutine write_file(path, content, ok)
    character(len=*), intent(in) :: path, content
    logical, intent(out) :: ok
    integer :: u, ios
    open(newunit=u, file=path, access='stream', form='unformatted', &
         status='replace', action='write', iostat=ios)
    ok = ios == 0
    if (.not. ok) return
    if (len(content) > 0) write(u) content
    close(u)
  end subroutine write_file

  subroutine read_file(path, content, ok)
    character(len=*), intent(in) :: path
    character(len=:), allocatable, intent(out) :: content
    logical, intent(out) :: ok
    integer :: u, ios, sz
    inquire(file=path, size=sz, exist=ok)
    if (.not. ok) then
      content = ''
      return
    end if
    if (allocated(content)) deallocate(content)
    allocate(character(len=sz) :: content)
    open(newunit=u, file=path, access='stream', form='unformatted', &
         status='old', action='read', iostat=ios)
    ok = ios == 0
    if (.not. ok) return
    if (sz > 0) read(u) content
    close(u)
  end subroutine read_file

  subroutine gpg(args, st)
    character(len=*), intent(in) :: args
    integer, intent(out) :: st
    call execute_command_line('gpg --batch --yes --pinentry-mode loopback ' // &
      '--passphrase "" --homedir "' // gnupg_home() // '" ' // args, exitstat=st)
  end subroutine gpg

  ! ---- keygen / attest --------------------------------------------------------

  function do_keygen() result(out)
    character(len=:), allocatable :: out
    character(len=:), allocatable :: pub, listing
    integer :: st
    call execute_command_line('mkdir -p "' // gnupg_home() // '" && chmod 700 "' // &
                              gnupg_home() // '"', exitstat=st)
    call gpg('--list-keys --with-colons > "' // tmp_dir() // '/keys.txt" 2>/dev/null', st)
    block
      logical :: rok
      call read_file(tmp_dir() // '/keys.txt', listing, rok)
    end block
    if (index(listing, 'pub:') == 0) then
      call gpg('--quick-gen-key "' // KEY_UID // '" ed25519 sign never 2>/dev/null', st)
    end if
    call gpg('--armor --export "' // KEY_UID // '" > "' // tmp_dir() // '/pub.asc" 2>/dev/null', st)
    block
      logical :: rok
      call read_file(tmp_dir() // '/pub.asc', pub, rok)
    end block
    out = '{"impl":"' // IMPL // '","pubkey":"' // json_escape(pub) // '"}'
  end function do_keygen

  ! Canonical JSON for a flat object: sorted top-level keys, value
  ! spans verbatim, optionally excluding one key.
  function canon_flat(obj, exclude) result(canon)
    character(len=*), intent(in) :: obj, exclude
    character(len=:), allocatable :: canon
    character(len=:), allocatable :: keys(:), vals(:)
    integer :: npairs, i, j, order(32)
    call json_top_pairs(obj, keys, vals, npairs)
    do i = 1, npairs
      order(i) = i
    end do
    ! insertion sort of order() by key text
    do i = 2, npairs
      block
        integer :: t, jj
        t = order(i)
        jj = i - 1
        do while (jj >= 1 .and. trim(keys(order(jj))) > trim(keys(t)))
          order(jj + 1) = order(jj)
          jj = jj - 1
        end do
        order(jj + 1) = t
      end block
    end do
    canon = '{'
    block
      logical :: first
      first = .true.
      do i = 1, npairs
        if (trim(keys(order(i))) == exclude) cycle
        if (.not. first) canon = canon // ','
        first = .false.
        canon = canon // '"' // trim(keys(order(i))) // '":' // trim(vals(order(i)))
      end do
    end block
    canon = canon // '}'
  end function canon_flat

  function do_attest(req) result(out)
    character(len=*), intent(in) :: req
    character(len=:), allocatable :: out
    character(len=:), allocatable :: desc, canon, sig
    logical :: found, ok
    integer :: st
    call json_get_object(req, 'descriptor', desc, found)
    if (.not. found) then
      out = '{"error":"missing descriptor"}'
      return
    end if
    canon = canon_flat(desc, '')
    call write_file(tmp_dir() // '/descriptor.json', canon, ok)
    call gpg('--detach-sign --armor --local-user "' // KEY_UID // '" --output "' // &
             tmp_dir() // '/descriptor.asc" "' // tmp_dir() // '/descriptor.json" 2>/dev/null', st)
    call read_file(tmp_dir() // '/descriptor.asc', sig, ok)
    out = '{"signature":"' // json_escape(sig) // '"}'
  end function do_attest

  logical function gpg_verify(pubkeys, data, sig)
    character(len=*), intent(in) :: pubkeys, data, sig
    logical :: ok
    integer :: st
    character(len=:), allocatable :: vdir
    vdir = tmp_dir() // '/verify'
    call execute_command_line('rm -rf "' // vdir // '" && mkdir -p "' // vdir // '/gnupg" && ' // &
                              'chmod 700 "' // vdir // '/gnupg"', exitstat=st)
    call write_file(vdir // '/keys.asc', pubkeys, ok)
    call write_file(vdir // '/descriptor.json', data, ok)
    call write_file(vdir // '/descriptor.asc', sig, ok)
    call execute_command_line('gpg --batch --yes --pinentry-mode loopback --homedir "' // &
      vdir // '/gnupg" --import "' // vdir // '/keys.asc" 2>/dev/null', exitstat=st)
    if (st /= 0) then
      gpg_verify = .false.
      return
    end if
    call execute_command_line('gpg --batch --yes --homedir "' // vdir // '/gnupg" --verify "' // &
      vdir // '/descriptor.asc" "' // vdir // '/descriptor.json" 2>/dev/null', exitstat=st)
    gpg_verify = st == 0
  end function gpg_verify

  ! ---- validate -----------------------------------------------------------------

  function do_init(req) result(out)
    character(len=*), intent(in) :: req
    character(len=:), allocatable :: out
    cache_state = get_state(req)
    cache_set = .true.
    out = '{"impl":"' // IMPL // '","verdict":"pass"}'
  end function do_init

  ! Driver-form validate (telephone.py cmd_play): the file already
  ! carries the placement scroll, the appended index line and the
  ! event scroll; the prior state is the serve cache set by init
  ! (advanced by each passing validate), or an explicit prior_state.
  ! Semantics mirror harness/adapter_base.py validate.
  function validate_driver(req, new_state, coord) result(out)
    character(len=*), intent(in) :: req, new_state
    integer, intent(in) :: coord(9)
    character(len=:), allocatable :: out
    character(len=:), allocatable :: ev_str, index_line, prior_b64, prior
    character(len=:), allocatable :: idx_text
    integer :: ev_coord(9), idx_coord(9)
    integer :: i, j, n, m
    logical :: found, ok, intact, seen
    type(scroll_t), allocatable :: before(:), after(:)
    idx_coord = [1, 1, 1, 1, 1, 1, 1, 1, 1]
    call json_get_string(req, 'event_coord', ev_str, found)
    call parse_coordinate(ev_str, ev_coord, ok)
    if (.not. ok) then
      out = validate_reply('fail', 'unparseable event coordinate')
      return
    end if
    call json_get_string(req, 'prior_state', prior_b64, found)
    if (found) then
      prior = b64_decode(prior_b64)
    else if (cache_set) then
      prior = cache_state
    else
      out = validate_reply('fail', 'no prior state (init not called)')
      return
    end if
    if (len(fetch(prior, coord)) /= 0) then
      out = validate_reply('fail', 'coordinate was not unused in the prior state')
      return
    end if
    call phokenize(prior, before)
    call phokenize(new_state, after)
    do i = 1, size(before)
      if (compare_coords(before(i)%coord, idx_coord) == 0) cycle
      intact = .false.
      do j = 1, size(after)
        if (compare_coords(after(j)%coord, before(i)%coord) == 0 .and. &
            after(j)%text == before(i)%text .and. &
            len(after(j)%text) == len(before(i)%text)) intact = .true.
      end do
      if (.not. intact) then
        out = validate_reply('fail', 'a prior scroll was overwritten')
        return
      end if
    end do
    do j = 1, size(after)
      if (compare_coords(after(j)%coord, coord) == 0) cycle
      if (compare_coords(after(j)%coord, ev_coord) == 0) cycle
      seen = .false.
      do i = 1, size(before)
        if (compare_coords(before(i)%coord, after(j)%coord) == 0) seen = .true.
      end do
      if (.not. seen) then
        out = validate_reply('fail', 'unexpected new scroll at ' // &
              format_coordinate(after(j)%coord))
        return
      end if
    end do
    call json_get_string(req, 'index_line', index_line, found)
    if (.not. found) index_line = ''
    idx_text = fetch(new_state, idx_coord)
    n = len(index_line)
    do while (n > 0 .and. (index_line(n:n) == char(10) .or. &
                           index_line(n:n) == char(13)))
      n = n - 1
    end do
    m = len(idx_text)
    do while (m > 0 .and. (idx_text(m:m) == char(10) .or. &
                           idx_text(m:m) == char(13)))
      m = m - 1
    end do
    if (n == 0 .or. m < n .or. idx_text(m-n+1:m) /= index_line(1:n)) then
      out = validate_reply('fail', 'index does not record the placement')
      return
    end if
    cache_state = new_state
    cache_set = .true.
    out = validate_reply('pass', 'placed at unused coordinate; all prior scrolls intact')
  end function validate_driver

  function do_validate(req) result(out)
    character(len=*), intent(in) :: req
    character(len=:), allocatable :: out
    character(len=:), allocatable :: op, coord_str, text, prior_b64
    character(len=:), allocatable :: ev_str
    character(len=:), allocatable :: new_state
    integer :: coord(9)
    logical :: ok, found, found_ev
    type(scroll_t), allocatable :: before(:), after(:)
    integer :: i, j
    logical :: intact
    call get_step(req, op, coord_str, text, ok)
    if (.not. ok) then
      out = '{"error":"missing step"}'
      return
    end if
    new_state = get_state(req)
    if (op /= 'insert') then
      out = validate_reply('fail', 'step op is not insert')
      return
    end if
    call parse_coordinate(coord_str, coord, ok)
    if (.not. ok) then
      out = validate_reply('fail', 'unparseable coordinate')
      return
    end if
    if (fetch(new_state, coord) /= text) then
      out = validate_reply('fail', 'placed scroll absent or content differs at ' // coord_str)
      return
    end if
    call json_get_string(req, 'event_coord', ev_str, found_ev)
    if (found_ev) then
      out = validate_driver(req, new_state, coord)
      return
    end if
    call json_get_string(req, 'prior_state', prior_b64, found)
    if (found) then
      block
        character(len=:), allocatable :: prior
        prior = b64_decode(prior_b64)
        if (len(fetch(prior, coord)) /= 0) then
          out = validate_reply('fail', 'coordinate was not unused in the prior state')
          return
        end if
        call phokenize(prior, before)
        call phokenize(new_state, after)
        if (size(after) /= size(before) + 1) then
          out = validate_reply('fail', 'scroll count did not grow by exactly one')
          return
        end if
        do i = 1, size(before)
          intact = .false.
          do j = 1, size(after)
            if (compare_coords(after(j)%coord, before(i)%coord) == 0 .and. &
                after(j)%text == before(i)%text .and. &
                len(after(j)%text) == len(before(i)%text)) intact = .true.
          end do
          if (.not. intact) then
            out = validate_reply('fail', 'a prior scroll was overwritten')
            return
          end if
        end do
        out = validate_reply('pass', 'placed at unused coordinate; all prior scrolls intact')
      end block
      return
    end if
    out = validate_reply('pass', 'placed scroll present with attested content (no prior state supplied)')
  end function do_validate

  function validate_reply(verdict, detail) result(out)
    character(len=*), intent(in) :: verdict, detail
    character(len=:), allocatable :: out
    out = '{"impl":"' // IMPL // '","verdict":"' // verdict // '","detail":"' // detail // '"}'
  end function validate_reply

  ! ---- verify -------------------------------------------------------------------

  function do_verify(req) result(out)
    character(len=*), intent(in) :: req
    character(len=:), allocatable :: out
    character(len=:), allocatable :: state, pubkeys
    character(len=:), allocatable :: keys_text, keys_hash, index_text
    character(len=64) :: prev_hash
    integer :: idx_coord(9), keys_coord(9), hash_coord(9), ev_coord(9), coord(9)
    integer :: checked, seq
    logical :: found
    type(scroll_t), allocatable :: scrolls(:)
    call json_get_string(req, 'pubkeys', pubkeys, found)
    if (.not. found) pubkeys = ''
    state = get_state(req)
    call parse_coordinate('1.1.1/1.1.1/1.1.1', idx_coord, found)
    call parse_coordinate('1.1.1/1.1.1/1.1.2', keys_coord, found)
    call parse_coordinate('1.1.1/1.1.1/1.1.3', hash_coord, found)
    keys_text = fetch(state, keys_coord)
    if (len(keys_text) == 0) then
      out = verify_fail('no public-keys scroll at 1.1.1/1.1.1/1.1.2', 0)
      return
    end if
    if (trim_right(pubkeys) /= trim_right(keys_text)) then
      out = verify_fail('supplied pubkeys do not match the inscribed keys scroll', 0)
      return
    end if
    keys_hash = fetch(state, hash_coord)
    if (len(keys_hash) == 0) then
      out = verify_fail('no keys-hash scroll at 1.1.1/1.1.1/1.1.3', 0)
      return
    end if
    ! Pinned: keys-hash is sha256 of the keys scroll text exactly as
    ! inscribed — no trimming.
    if (trim(keys_hash) /= sha256_hex(keys_text)) then
      out = verify_fail('keys-hash scroll does not match the keys scroll', 0)
      return
    end if
    index_text = fetch(state, idx_coord)
    call phokenize(state, scrolls)
    checked = 0
    seq = 1
    do
      ev_coord = [1, 1, 1, 1, 1, 1, 2, 1, seq]
      block
        character(len=:), allocatable :: event_text, body_text, prev_str, etype
        character(len=:), allocatable :: coord_str, scroll_hash, file_hash, att_b64
        character(len=:), allocatable :: actor, sig, placement, descriptor
        integer :: turn
        logical :: have, pf, tf
        event_text = fetch(state, ev_coord)
        if (len(event_text) == 0) then
          if (seq == 1) then
            out = verify_fail('no event scrolls found', 0)
            return
          end if
          exit
        end if
        call json_get_object(event_text, 'body', body_text, have)
        if (.not. have) then
          out = verify_fail('event lacks a body object', checked)
          return
        end if
        ! Pinned event chain: prev = sha256 of the previous event's
        ! canonical body (the inscribed body span is already in
        ! canonical form), null for the first event.
        call json_get_string(event_text, 'prev', prev_str, pf)
        if (seq == 1) then
          if (pf) then
            out = verify_fail('event 1 prev is not null', checked)
            return
          end if
        else
          if (.not. pf .or. prev_str /= prev_hash) then
            out = verify_fail('event chain broken at seq ' // intstr(seq), checked)
            return
          end if
        end if
        prev_hash = sha256_hex(body_text)
        call json_get_string(body_text, 'type', etype, have)
        if (.not. have .or. etype /= 'placement') then
          seq = seq + 1
          cycle
        end if
        block
          logical :: f1, f2, f3, f4, f5, f6
          call json_get_string(body_text, 'coord', coord_str, f1)
          call json_get_string(body_text, 'text_sha256', scroll_hash, f2)
          call json_get_string(body_text, 'file_sha256', file_hash, f3)
          call json_get_string(body_text, 'att', att_b64, f4)
          call json_get_string(body_text, 'actor', actor, f5)
          call json_get_int(body_text, 'turn', turn, f6)
          have = f1 .and. f2 .and. f3 .and. f4 .and. f5 .and. f6
        end block
        if (.not. have) then
          out = verify_fail('event lacks coord/text_sha256/file_sha256/att/actor/turn', checked)
          return
        end if
        call parse_coordinate(coord_str, coord, found)
        placement = fetch(state, coord)
        if (len(placement) == 0) then
          out = verify_fail('placement missing at ' // coord_str, checked)
          return
        end if
        if (sha256_hex(placement) /= scroll_hash) then
          out = verify_fail('placement hash mismatch at ' // coord_str, checked)
          return
        end if
        if (.not. index_has(index_text, coord_str, scroll_hash, intstr(turn), actor)) then
          out = verify_fail('index mismatch at ' // coord_str, checked)
          return
        end if
        ! Pinned attestation descriptor (flat canonical JSON, keys
        ! sorted); att is base64 of the armored detached signature.
        descriptor = '{"coordinate":"' // coord_str // '","file_sha256":"' // &
          file_hash // '","scroll_sha256":"' // scroll_hash // '","turn":' // &
          intstr(turn) // '}'
        sig = b64_decode(att_b64)
        if (.not. gpg_verify(pubkeys, descriptor, sig)) then
          out = verify_fail('event signature invalid', checked)
          return
        end if
        checked = checked + 1
        seq = seq + 1
      end block
    end do
    if (checked == 0) then
      out = verify_fail('no placement events found', 0)
      return
    end if
    ! every index line must correspond to a checked event placement
    block
      integer :: pos, nl, nlines
      character(len=:), allocatable :: line, c1
      logical :: tf
      nlines = 0
      pos = 1
      do while (pos <= len(index_text))
        nl = index(index_text(pos:), achar(10))
        if (nl == 0) then
          line = index_text(pos:)
          pos = len(index_text) + 1
        else
          if (nl == 1) then
            line = ''
          else
            line = index_text(pos:pos + nl - 2)
          end if
          pos = pos + nl
        end if
        if (len_trim(line) == 0) cycle
        if (line(1:1) == '#') cycle
        nlines = nlines + 1
        call nth_field(line, 2, c1, tf)
        if (.not. tf) then
          out = verify_fail('malformed index line', checked)
          return
        end if
        ! No per-line event re-walk here (that is O(n^2) in fetches):
        ! the main loop already matched every placement event to its
        ! index line on (turn, coord, hash, actor), so an index line
        ! with no placement event would leave some placement unmatched
        ! (caught above) or inflate this count (caught below).
      end do
      if (nlines /= checked) then
        out = verify_fail('index line count differs from placement count', checked)
        return
      end if
    end block
    out = '{"impl":"' // IMPL // '","verdict":"pass","placements_checked":' // &
          intstr(checked) // ',"first_failure":null}'
  end function do_verify

  logical function event_has_coord(state, coord_str)
    character(len=*), intent(in) :: state, coord_str
    integer :: coord(9), ev(9), seq
    logical :: ok
    character(len=:), allocatable :: event_text, body_text, cs
    logical :: have, have_body
    event_has_coord = .false.
    call parse_coordinate(coord_str, coord, ok)
    if (.not. ok) return
    seq = 1
    do
      ev = [1, 1, 1, 1, 1, 1, 2, 1, seq]
      event_text = fetch(state, ev)
      if (len(event_text) == 0) return
      call json_get_object(event_text, 'body', body_text, have_body)
      if (have_body) then
        call json_get_string(body_text, 'coord', cs, have)
        if (have .and. cs == coord_str) then
          event_has_coord = .true.
          return
        end if
      end if
      seq = seq + 1
    end do
  end function event_has_coord

  ! Extract the n-th space-separated field of a line.
  subroutine nth_field(line, n, field, found)
    character(len=*), intent(in) :: line
    integer, intent(in) :: n
    character(len=:), allocatable, intent(out) :: field
    logical, intent(out) :: found
    integer :: i, count, start
    found = .false.
    field = ''
    count = 0
    i = 1
    do while (i <= len(line))
      do while (i <= len(line) .and. line(i:i) == ' ')
        i = i + 1
      end do
      if (i > len(line)) exit
      count = count + 1
      start = i
      do while (i <= len(line) .and. line(i:i) /= ' ')
        i = i + 1
      end do
      if (count == n) then
        field = line(start:i - 1)
        found = .true.
        return
      end if
    end do
  end subroutine nth_field

  ! Pinned index line: "<turn> <coordinate> <sha256> <actor id>".
  logical function index_has(index_text, coord_str, hash, turn_str, actor)
    character(len=*), intent(in) :: index_text, coord_str, hash, turn_str, actor
    integer :: pos, nl
    character(len=:), allocatable :: line, f1, f2, f3, f4
    logical :: ok1, ok2, ok3, ok4
    index_has = .false.
    pos = 1
    do while (pos <= len(index_text))
      nl = index(index_text(pos:), achar(10))
      if (nl == 0) then
        line = index_text(pos:)
        pos = len(index_text) + 1
      else
        if (nl == 1) then
          line = ''
        else
          line = index_text(pos:pos + nl - 2)
        end if
        pos = pos + nl
      end if
      if (len_trim(line) == 0) cycle
      if (line(1:1) == '#') cycle
      call nth_field(line, 1, f1, ok1)
      call nth_field(line, 2, f2, ok2)
      call nth_field(line, 3, f3, ok3)
      call nth_field(line, 4, f4, ok4)
      if (ok1 .and. ok2 .and. ok3 .and. ok4 .and. f1 == turn_str .and. &
          f2 == coord_str .and. f3 == hash .and. f4 == actor) then
        index_has = .true.
        return
      end if
    end do
  end function index_has

  function trim_right(s) result(t)
    character(len=*), intent(in) :: s
    character(len=:), allocatable :: t
    integer :: n
    n = len(s)
    do while (n > 0 .and. (s(n:n) == ' ' .or. s(n:n) == char(9) .or. &
                           s(n:n) == char(10) .or. s(n:n) == char(13)))
      n = n - 1
    end do
    if (n == 0) then
      t = ''
    else
      t = s(1:n)
    end if
  end function trim_right

  function verify_fail(msg, checked) result(out)
    character(len=*), intent(in) :: msg
    integer, intent(in) :: checked
    character(len=:), allocatable :: out
    out = '{"impl":"' // IMPL // '","verdict":"fail","placements_checked":' // &
          intstr(checked) // ',"first_failure":{"detail":"' // msg // '"}}'
  end function verify_fail

end program telephone
