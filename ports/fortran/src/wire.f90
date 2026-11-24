! wire.f90 - SHA-256, base64, and minimal JSON field extraction for the
! Fortran telephone CLI. SHA-256 words are held in int64 in [0, 2^32) so
! every add/shift/rotate is exact; no signed-overflow tricks.
module wire_mod
  use, intrinsic :: iso_fortran_env, only: int64
  implicit none
  private
  public :: sha256_hex, b64_encode, b64_decode
  public :: json_get_string, json_get_int, json_get_object
  public :: json_parse_string_at, json_top_pairs, json_escape, json_get_string_array

  integer(int64), parameter :: MASK32 = 4294967295_int64
  integer(int64), parameter :: K256(64) = [ &
    1116352408_int64, 1899447441_int64, 3049323471_int64, 3921009573_int64, &
    961987163_int64, 1508970993_int64, 2453635748_int64, 2870763221_int64, &
    3624381080_int64, 310598401_int64, 607225278_int64, 1426881987_int64, &
    1925078388_int64, 2162078206_int64, 2614888103_int64, 3248222580_int64, &
    3835390401_int64, 4022224774_int64, 264347078_int64, 604807628_int64, &
    770255983_int64, 1249150122_int64, 1555081692_int64, 1996064986_int64, &
    2554220882_int64, 2821834349_int64, 2952996808_int64, 3210313671_int64, &
    3336571891_int64, 3584528711_int64, 113926993_int64, 338241895_int64, &
    666307205_int64, 773529912_int64, 1294757372_int64, 1396182291_int64, &
    1695183700_int64, 1986661051_int64, 2177026350_int64, 2456956037_int64, &
    2730485921_int64, 2820302411_int64, 3259730800_int64, 3345764771_int64, &
    3516065817_int64, 3600352804_int64, 4094571909_int64, 275423344_int64, &
    430227734_int64, 506948616_int64, 659060556_int64, 883997877_int64, &
    958139571_int64, 1322822218_int64, 1537002063_int64, 1747873779_int64, &
    1955562222_int64, 2024104815_int64, 2227730452_int64, 2361852424_int64, &
    2428436474_int64, 2756734187_int64, 3204031479_int64, 3329325298_int64]

contains

  integer(int64) function rotr(x, n)
    integer(int64), intent(in) :: x
    integer, intent(in) :: n
    rotr = iand(ior(ishft(x, -n), ishft(x, 32 - n)), MASK32)
  end function rotr

  function sha256_hex(data) result(hex)
    character(len=*), intent(in) :: data
    character(len=64) :: hex
    integer(int64) :: h(0:7), w(0:63), a, b, c, d, e, f, g, hh
    integer(int64) :: s0, s1, ss0, ss1, ch, maj, t1, t2
    integer, allocatable :: msg(:)
    integer :: n, total, blk, i, t, pos
    character(len=16), parameter :: HEXD = '0123456789abcdef'
    h = [1779033703_int64, 3144134277_int64, 1013904242_int64, 2773480762_int64, &
         1359893119_int64, 2600822924_int64, 528734635_int64, 1541459225_int64]
    n = len(data)
    total = ((n + 9 + 63) / 64) * 64
    allocate(msg(total))
    msg = 0
    do i = 1, n
      msg(i) = iachar(data(i:i))
    end do
    msg(n + 1) = 128
    ! 64-bit big-endian bit length in the last 8 bytes
    block
      integer(int64) :: bits
      bits = int(n, int64) * 8_int64
      do i = 0, 7
        msg(total - i) = int(iand(ishft(bits, -8 * i), 255_int64))
      end do
    end block
    do blk = 0, total / 64 - 1
      do t = 0, 15
        pos = blk * 64 + t * 4
        w(t) = int(msg(pos + 1), int64) * 16777216_int64 + int(msg(pos + 2), int64) * 65536_int64 &
             + int(msg(pos + 3), int64) * 256_int64 + int(msg(pos + 4), int64)
      end do
      do t = 16, 63
        ss0 = ieor(ieor(rotr(w(t - 15), 7), rotr(w(t - 15), 18)), ishft(w(t - 15), -3))
        ss1 = ieor(ieor(rotr(w(t - 2), 17), rotr(w(t - 2), 19)), ishft(w(t - 2), -10))
        w(t) = iand(w(t - 16) + ss0 + w(t - 7) + ss1, MASK32)
      end do
      a = h(0); b = h(1); c = h(2); d = h(3); e = h(4); f = h(5); g = h(6); hh = h(7)
      do t = 0, 63
        s1 = ieor(ieor(rotr(e, 6), rotr(e, 11)), rotr(e, 25))
        ch = ieor(iand(e, f), iand(ieor(e, MASK32), g))
        t1 = iand(hh + s1 + ch + K256(t + 1) + w(t), MASK32)
        s0 = ieor(ieor(rotr(a, 2), rotr(a, 13)), rotr(a, 22))
        maj = ieor(ieor(iand(a, b), iand(a, c)), iand(b, c))
        t2 = iand(s0 + maj, MASK32)
        hh = g; g = f; f = e; e = iand(d + t1, MASK32)
        d = c; c = b; b = a; a = iand(t1 + t2, MASK32)
      end do
      h(0) = iand(h(0) + a, MASK32); h(1) = iand(h(1) + b, MASK32)
      h(2) = iand(h(2) + c, MASK32); h(3) = iand(h(3) + d, MASK32)
      h(4) = iand(h(4) + e, MASK32); h(5) = iand(h(5) + f, MASK32)
      h(6) = iand(h(6) + g, MASK32); h(7) = iand(h(7) + hh, MASK32)
    end do
    hex = ''
    do i = 0, 7
      do t = 7, 0, -1
        hex(i * 8 + 8 - t:i * 8 + 8 - t) = HEXD(int(iand(ishft(h(i), -4 * t), 15_int64)) + 1: &
                                                int(iand(ishft(h(i), -4 * t), 15_int64)) + 1)
      end do
    end do
  end function sha256_hex

  function b64_encode(data) result(out)
    character(len=*), intent(in) :: data
    character(len=:), allocatable :: out
    character(len=64), parameter :: ALPHA = &
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    integer :: n, i, olen, o, b0, b1, b2
    n = len(data)
    olen = ((n + 2) / 3) * 4
    allocate(character(len=olen) :: out)
    o = 0
    do i = 1, n, 3
      b0 = iachar(data(i:i))
      b1 = 0; b2 = 0
      if (i + 1 <= n) b1 = iachar(data(i + 1:i + 1))
      if (i + 2 <= n) b2 = iachar(data(i + 2:i + 2))
      o = o + 1; out(o:o) = ALPHA(ibits(b0, 2, 6) + 1:ibits(b0, 2, 6) + 1)
      o = o + 1; out(o:o) = ALPHA(ior(ishft(iand(b0, 3), 4), ibits(b1, 4, 4)) + 1: &
                                  ior(ishft(iand(b0, 3), 4), ibits(b1, 4, 4)) + 1)
      if (i + 1 <= n) then
        o = o + 1; out(o:o) = ALPHA(ior(ishft(iand(b1, 15), 2), ibits(b2, 6, 2)) + 1: &
                                    ior(ishft(iand(b1, 15), 2), ibits(b2, 6, 2)) + 1)
      else
        o = o + 1; out(o:o) = '='
      end if
      if (i + 2 <= n) then
        o = o + 1; out(o:o) = ALPHA(iand(b2, 63) + 1:iand(b2, 63) + 1)
      else
        o = o + 1; out(o:o) = '='
      end if
    end do
    if (olen == 0) out = ''
  end function b64_encode

  integer function b64_val(ch) result(v)
    character, intent(in) :: ch
    character(len=64), parameter :: ALPHA = &
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    v = index(ALPHA, ch) - 1
  end function b64_val

  function b64_decode(data) result(out)
    character(len=*), intent(in) :: data
    character(len=:), allocatable :: out
    integer :: n, i, o, olen, v0, v1, v2, v3
    ! count non-padding chars
    n = len(data)
    olen = (n / 4) * 3
    if (n >= 2) then
      if (data(n:n) == '=') olen = olen - 1
      if (data(n - 1:n - 1) == '=') olen = olen - 1
    end if
    allocate(character(len=max(olen, 0)) :: out)
    o = 0
    do i = 1, n, 4
      v0 = b64_val(data(i:i)); v1 = b64_val(data(i + 1:i + 1))
      v2 = 0; v3 = 0
      if (data(i + 2:i + 2) /= '=') v2 = b64_val(data(i + 2:i + 2))
      if (data(i + 3:i + 3) /= '=') v3 = b64_val(data(i + 3:i + 3))
      o = o + 1; if (o <= olen) out(o:o) = achar(ior(ishft(v0, 2), ibits(v1, 4, 2)))
      o = o + 1; if (o <= olen) out(o:o) = achar(ior(ishft(iand(v1, 15), 4), ibits(v2, 2, 4)))
      o = o + 1; if (o <= olen) out(o:o) = achar(ior(ishft(iand(v2, 3), 6), v3))
    end do
    if (olen == 0) out = ''
  end function b64_decode

  ! --- Minimal JSON extraction -------------------------------------------
  ! Finds "key" in text; returns the raw value span [vstart, vend].
  subroutine json_value_span(text, key, vstart, vend, found)
    character(len=*), intent(in) :: text, key
    integer, intent(out) :: vstart, vend
    logical, intent(out) :: found
    integer :: i, klen
    found = .false.
    vstart = 0; vend = -1
    klen = len(key)
    i = 1
    do while (i + klen + 1 <= len(text))
      if (text(i:i) == '"' .and. text(i + 1:i + klen) == key .and. &
          text(i + klen + 1:i + klen + 1) == '"') then
        i = i + klen + 2
        do while (i <= len(text) .and. (text(i:i) == ' ' .or. text(i:i) == char(9)))
          i = i + 1
        end do
        if (i > len(text) .or. text(i:i) /= ':') return
        i = i + 1
        do while (i <= len(text) .and. (text(i:i) == ' ' .or. text(i:i) == char(9)))
          i = i + 1
        end do
        vstart = i
        call json_span_end(text, vstart, vend)
        found = vend >= vstart
        return
      end if
      i = i + 1
    end do
  end subroutine json_value_span

  subroutine json_span_end(text, start, vend)
    character(len=*), intent(in) :: text
    integer, intent(in) :: start
    integer, intent(out) :: vend
    integer :: i, depth
    logical :: in_str, esc
    vend = start - 1
    if (start > len(text)) return
    select case (text(start:start))
    case ('"')
      i = start + 1
      esc = .false.
      do while (i <= len(text))
        if (esc) then
          esc = .false.
        else if (text(i:i) == '\') then
          esc = .true.
        else if (text(i:i) == '"') then
          vend = i
          return
        end if
        i = i + 1
      end do
    case ('{', '[')
      depth = 0
      in_str = .false.
      esc = .false.
      i = start
      do while (i <= len(text))
        if (in_str) then
          if (esc) then
            esc = .false.
          else if (text(i:i) == '\') then
            esc = .true.
          else if (text(i:i) == '"') then
            in_str = .false.
          end if
        else
          select case (text(i:i))
          case ('"')
            in_str = .true.
          case ('{', '[')
            depth = depth + 1
          case ('}', ']')
            depth = depth - 1
            if (depth == 0) then
              vend = i
              return
            end if
          end select
        end if
        i = i + 1
      end do
    case default
      i = start
      do while (i <= len(text))
        if (text(i:i) == ',' .or. text(i:i) == '}' .or. text(i:i) == ']' .or. &
            text(i:i) == ' ' .or. text(i:i) == char(10) .or. text(i:i) == char(13)) then
          vend = i - 1
          return
        end if
        i = i + 1
      end do
      vend = len(text)
    end select
  end subroutine json_span_end

  ! Extract a string field, unescaping \" \\ \/ \n \t \r and \uXXXX (BMP,
  ! encoded as UTF-8). found=.false. when absent or not a string.
  subroutine json_get_string(text, key, val, found)
    character(len=*), intent(in) :: text, key
    character(len=:), allocatable, intent(out) :: val
    logical, intent(out) :: found
    integer :: vs, ve, i, o, cp, j
    character(len=:), allocatable :: buf
    call json_value_span(text, key, vs, ve, found)
    val = ''
    if (.not. found) return
    if (text(vs:vs) /= '"') then
      found = .false.
      return
    end if
    allocate(character(len=ve - vs) :: buf)
    o = 0
    i = vs + 1
    do while (i < ve)
      if (text(i:i) == '\' .and. i + 1 <= ve) then
        select case (text(i + 1:i + 1))
        case ('n'); o = o + 1; buf(o:o) = char(10); i = i + 2
        case ('t'); o = o + 1; buf(o:o) = char(9); i = i + 2
        case ('r'); o = o + 1; buf(o:o) = char(13); i = i + 2
        case ('u')
          cp = 0
          do j = 0, 3
            cp = cp * 16 + hexval(text(i + 2 + j:i + 2 + j))
          end do
          if (cp < 128) then
            o = o + 1; buf(o:o) = achar(cp)
          else if (cp < 2048) then
            o = o + 1; buf(o:o) = achar(ior(192, ibits(cp, 6, 5)))
            o = o + 1; buf(o:o) = achar(ior(128, iand(cp, 63)))
          else
            o = o + 1; buf(o:o) = achar(ior(224, ibits(cp, 12, 4)))
            o = o + 1; buf(o:o) = achar(ior(128, iand(ishft(cp, -6), 63)))
            o = o + 1; buf(o:o) = achar(ior(128, iand(cp, 63)))
          end if
          i = i + 6
        case default
          o = o + 1; buf(o:o) = text(i + 1:i + 1); i = i + 2
        end select
      else
        o = o + 1; buf(o:o) = text(i:i); i = i + 1
      end if
    end do
    val = buf(1:o)
    if (o == 0) val = ''
  end subroutine json_get_string

  integer function hexval(ch)
    character, intent(in) :: ch
    if (ch >= '0' .and. ch <= '9') then
      hexval = iachar(ch) - iachar('0')
    else if (ch >= 'a' .and. ch <= 'f') then
      hexval = iachar(ch) - iachar('a') + 10
    else
      hexval = iachar(ch) - iachar('A') + 10
    end if
  end function hexval

  subroutine json_get_int(text, key, val, found)
    character(len=*), intent(in) :: text, key
    integer, intent(out) :: val
    logical, intent(out) :: found
    integer :: vs, ve, i
    call json_value_span(text, key, vs, ve, found)
    val = 0
    if (.not. found) return
    i = vs
    if (text(i:i) == '-') i = i + 1
    do while (i <= ve .and. text(i:i) >= '0' .and. text(i:i) <= '9')
      val = val * 10 + (iachar(text(i:i)) - iachar('0'))
      i = i + 1
    end do
    if (text(vs:vs) == '-') val = -val
  end subroutine json_get_int

  ! Parse a JSON string starting at pos (text(pos:pos) must be '"').
  ! Returns the decoded value and the position just past the closing
  ! quote. Handles \" \\ \/ \b \f \n \r \t and \uXXXX (BMP, UTF-8 out).
  subroutine json_parse_string_at(text, pos, val, nextpos, ok)
    character(len=*), intent(in) :: text
    integer, intent(in) :: pos
    character(len=:), allocatable, intent(out) :: val
    integer, intent(out) :: nextpos
    logical, intent(out) :: ok
    integer :: i, o, cp, j
    character(len=:), allocatable :: buf
    ok = .false.
    val = ''
    nextpos = pos
    if (pos > len(text)) return
    if (text(pos:pos) /= '"') return
    allocate(character(len=len(text)) :: buf)
    o = 0
    i = pos + 1
    do while (i <= len(text))
      if (text(i:i) == '"') then
        nextpos = i + 1
        ok = .true.
        if (o == 0) then
          val = ''
        else
          val = buf(1:o)
        end if
        return
      else if (text(i:i) == '\' .and. i + 1 <= len(text)) then
        select case (text(i + 1:i + 1))
        case ('n'); o = o + 1; buf(o:o) = char(10); i = i + 2
        case ('t'); o = o + 1; buf(o:o) = char(9); i = i + 2
        case ('r'); o = o + 1; buf(o:o) = char(13); i = i + 2
        case ('b'); o = o + 1; buf(o:o) = char(8); i = i + 2
        case ('f'); o = o + 1; buf(o:o) = char(12); i = i + 2
        case ('u')
          cp = 0
          do j = 0, 3
            cp = cp * 16 + hexval(text(i + 2 + j:i + 2 + j))
          end do
          if (cp < 128) then
            o = o + 1; buf(o:o) = achar(cp)
          else if (cp < 2048) then
            o = o + 1; buf(o:o) = achar(ior(192, ibits(cp, 6, 5)))
            o = o + 1; buf(o:o) = achar(ior(128, iand(cp, 63)))
          else
            o = o + 1; buf(o:o) = achar(ior(224, ibits(cp, 12, 4)))
            o = o + 1; buf(o:o) = achar(ior(128, iand(ishft(cp, -6), 63)))
            o = o + 1; buf(o:o) = achar(ior(128, iand(cp, 63)))
          end if
          i = i + 6
        case default
          o = o + 1; buf(o:o) = text(i + 1:i + 1); i = i + 2
        end select
      else
        o = o + 1; buf(o:o) = text(i:i); i = i + 1
      end if
    end do
  end subroutine json_parse_string_at

  ! Enumerate the top-level pairs of a flat JSON object: keys(i) is the
  ! decoded key, vals(i) the raw JSON span of the value (strings keep
  ! their quotes/escapes). Used to build canonical JSON for flat
  ! objects (step descriptors are flat by contract).
  subroutine json_top_pairs(text, keys, vals, npairs)
    character(len=*), intent(in) :: text
    character(len=:), allocatable, intent(out) :: keys(:), vals(:)
    integer, intent(out) :: npairs
    integer :: i, vs, ve, alloc_n
    character(len=:), allocatable :: k
    logical :: ok
    alloc_n = 32
    allocate(character(len=256) :: keys(alloc_n))
    allocate(character(len=8192) :: vals(alloc_n))
    npairs = 0
    i = index(text, '{')
    if (i == 0) return
    i = i + 1
    do
      do while (i <= len(text) .and. (text(i:i) == ' ' .or. text(i:i) == ',' .or. &
                                      text(i:i) == char(9) .or. text(i:i) == char(10) .or. &
                                      text(i:i) == char(13)))
        i = i + 1
      end do
      if (i > len(text) .or. text(i:i) == '}') exit
      call json_parse_string_at(text, i, k, i, ok)
      if (.not. ok) exit
      do while (i <= len(text) .and. (text(i:i) == ' ' .or. text(i:i) == ':'))
        i = i + 1
      end do
      call json_span_end(text, i, ve)
      if (ve < i) exit
      vs = i
      i = ve + 1
      npairs = npairs + 1
      if (npairs > alloc_n) exit
      keys(npairs) = k
      vals(npairs) = text(vs:ve)
    end do
  end subroutine json_top_pairs

  ! Extract an array-of-strings field: values(1..n).
  subroutine json_get_string_array(text, key, values, n, found)
    character(len=*), intent(in) :: text, key
    character(len=:), allocatable, intent(out) :: values(:)
    integer, intent(out) :: n
    logical, intent(out) :: found
    integer :: vs, ve, i
    character(len=:), allocatable :: v
    logical :: ok
    call json_value_span(text, key, vs, ve, found)
    n = 0
    allocate(character(len=256) :: values(64))
    if (.not. found) return
    if (text(vs:vs) /= '[') then
      found = .false.
      return
    end if
    i = vs + 1
    do while (i < ve)
      if (text(i:i) == '"') then
        call json_parse_string_at(text, i, v, i, ok)
        if (.not. ok) exit
        n = n + 1
        if (n <= 64) values(n) = v
      else
        i = i + 1
      end if
    end do
  end subroutine json_get_string_array

  ! Escape a string for inclusion in JSON output.
  function json_escape(str) result(out)
    character(len=*), intent(in) :: str
    character(len=:), allocatable :: out
    integer :: i, o
    allocate(character(len=len(str) * 2 + 2) :: out)
    o = 0
    do i = 1, len(str)
      select case (str(i:i))
      case ('"'); out(o + 1:o + 2) = '\"'; o = o + 2
      case ('\'); out(o + 1:o + 2) = '\\'; o = o + 2
      case (char(10)); out(o + 1:o + 2) = '\n'; o = o + 2
      case (char(13)); out(o + 1:o + 2) = '\r'; o = o + 2
      case (char(9)); out(o + 1:o + 2) = '\t'; o = o + 2
      case default
        o = o + 1; out(o:o) = str(i:i)
      end select
    end do
    out = out(1:o)
    if (o == 0) out = ''
  end function json_escape

  subroutine json_get_object(text, key, val, found)
    character(len=*), intent(in) :: text, key
    character(len=:), allocatable, intent(out) :: val
    logical, intent(out) :: found
    integer :: vs, ve
    call json_value_span(text, key, vs, ve, found)
    val = ''
    if (.not. found) return
    if (text(vs:vs) /= '{') then
      found = .false.
      return
    end if
    val = text(vs:ve)
  end subroutine json_get_object

end module wire_mod
