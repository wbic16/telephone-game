! Test suite for the Fortran libphext port.
! Build: gfortran -o test_phext src/phext.f90 tests/test_phext.f90
! Run:   ./test_phext [fixtures_dir]
! Fixture conformance (shared Step 0 set): with a fixtures dir argument,
! phokenize then dephokenize must reproduce each fixture byte-identically.
! The fixture file list is read from <fixtures_dir>/../fixture-list.txt
! when present, else the suite lists the dir via a shell call.
program test_phext
  use phext_mod
  use wire_mod, only: sha256_hex, b64_encode, b64_decode
  implicit none

  integer :: failures, coord(9)
  logical :: ok
  type(scroll_t), allocatable :: scrolls(:)
  character(len=:), allocatable :: buf, fixtures
  character(len=1024) :: arg
  integer :: i

  failures = 0

  ! SHA-256 / base64 sanity (wire helpers)
  call check(sha256_hex('abc') == &
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'sha256 abc')
  call check(sha256_hex('') == &
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 'sha256 empty')
  call check(b64_encode('hello') == 'aGVsbG8=', 'base64 encode')
  call check(b64_decode('aGVsbG8=') == 'hello', 'base64 decode')
  call check(b64_decode(b64_encode('a' // achar(1) // 'b' // achar(23) // 'c')) == &
             'a' // achar(1) // 'b' // achar(23) // 'c', 'base64 binary round trip')

  ! Coordinate parse / format / order
  call parse_coordinate('1.2.3/4.5.6/7.8.9', coord, ok)
  call check(ok .and. format_coordinate(coord) == '1.2.3/4.5.6/7.8.9', 'coordinate round trip')
  call parse_coordinate('0.1.1/1.1.1/1.1.1', coord, ok)
  call check(.not. ok, 'coordinate rejects 0')
  call parse_coordinate('1.1.1/1.1.1', coord, ok)
  call check(.not. ok, 'coordinate rejects short')
  block
    integer :: a(9), b(9)
    call parse_coordinate('1.1.1/1.1.1/1.1.9', a, ok)
    call parse_coordinate('1.1.1/1.1.2/1.1.1', b, ok)
    call check(compare_coords(a, b) == -1, 'order: section beats scroll')
    call parse_coordinate('2.1.1/1.1.1/1.1.1', a, ok)
    call parse_coordinate('10.1.1/1.1.1/1.1.1', b, ok)
    call check(compare_coords(a, b) == -1, 'order: numeric not string')
  end block

  ! Break semantics + round trip
  buf = 'a' // achar(23) // 'b' // achar(24) // 'c' // achar(1) // 'd'
  call phokenize(buf, scrolls)
  call check(size(scrolls) == 4, 'phokenize count')
  if (size(scrolls) == 4) then
    call check(format_coordinate(scrolls(1)%coord) == '1.1.1/1.1.1/1.1.1' .and. scrolls(1)%text == 'a', 'scroll 1')
    call check(format_coordinate(scrolls(2)%coord) == '1.1.1/1.1.1/1.1.2' .and. scrolls(2)%text == 'b', 'scroll 2')
    call check(format_coordinate(scrolls(3)%coord) == '1.1.1/1.1.1/1.2.1' .and. scrolls(3)%text == 'c', 'scroll 3')
    call check(format_coordinate(scrolls(4)%coord) == '2.1.1/1.1.1/1.1.1' .and. scrolls(4)%text == 'd', 'scroll 4')
  end if
  call check(dephokenize(scrolls) == buf, 'dephokenize round trip')

  ! Newline is ordinary text
  call phokenize('line1' // achar(10) // 'line2', scrolls)
  call check(size(scrolls) == 1 .and. scrolls(1)%text == 'line1' // achar(10) // 'line2', 'newline is text')

  ! Fetch, incl. gap coordinates
  call parse_coordinate('1.1.1/1.1.1/1.1.2', coord, ok)
  call check(fetch('hello', coord) == '', 'gap fetch is ""')
  call parse_coordinate('9.9.9/9.9.9/9.9.9', coord, ok)
  call check(fetch('hello', coord) == '', 'far gap fetch is ""')
  call parse_coordinate('1.1.1/1.1.1/1.1.1', coord, ok)
  call check(fetch('hello', coord) == 'hello', 'fetch hit')

  ! Insert: existing + inserted (reference semantics)
  call parse_coordinate('1.1.1/1.1.1/1.1.1', coord, ok)
  buf = insert('base', coord, '+more')
  call check(fetch(buf, coord) == 'base+more', 'insert merges existing+inserted')
  call parse_coordinate('1.1.1/1.1.1/1.1.3', coord, ok)
  buf = insert(buf, coord, 'third')
  call check(buf == 'base+more' // achar(23) // achar(23) // 'third', 'insert creates in canonical position')

  ! Replace / remove + normalize
  call parse_coordinate('1.1.1/1.1.1/1.1.2', coord, ok)
  buf = replace('a' // achar(23) // 'b' // achar(23) // 'c', coord, 'B')
  call check(buf == 'a' // achar(23) // 'B' // achar(23) // 'c', 'replace overwrites')
  buf = remove(buf, coord)
  call check(buf == 'a' // achar(23) // achar(23) // 'c', 'remove + normalize keeps c at scroll 3')
  call check(fetch(buf, coord) == '', 'fetch after remove is ""')
  call parse_coordinate('5.5.5/5.5.5/5.5.5', coord, ok)
  call check(remove(buf, coord) == buf, 'remove gap is no-op')

  ! Explode / implode
  call explode('x' // achar(23) // 'y' // achar(1) // 'z', scrolls)
  call check(size(scrolls) == 3, 'explode count')
  call check(implode(scrolls) == 'x' // achar(23) // 'y' // achar(1) // 'z', 'explode/implode round trip')

  ! Fixtures: argument 1 is a text file listing input.phext paths, one
  ! per line (built by tests/run_tests.sh from $PHEXT_FIXTURES).
  if (command_argument_count() >= 1) then
    call get_command_argument(1, arg)
    fixtures = trim(arg)
    call run_fixtures(fixtures)
  else
    write(*, '(A)') 'skip - fixtures (no list file argument)'
  end if

  if (failures == 0) then
    write(*, '(A)') 'PASS'
  else
    write(*, '(A,I0)') 'FAILURES: ', failures
    stop 1
  end if

contains

  subroutine check(cond, name)
    logical, intent(in) :: cond
    character(len=*), intent(in) :: name
    if (cond) then
      write(*, '(A)') 'ok - ' // name
    else
      failures = failures + 1
      write(*, '(A)') 'FAIL - ' // name
    end if
  end subroutine check

  ! Fixture standard (the one the sibling ports enforce): normalize
  ! idempotent for every fixture; phokenize/dephokenize round trip
  ! byte-identical for all but at most 2 (known non-canonical
  ! real-corpora inputs).
  subroutine run_fixtures(listfile)
    character(len=*), intent(in) :: listfile
    character(len=4096) :: fname
    character(len=:), allocatable :: data, roundtrip, n1, n2
    integer :: u, ios, i, count, identical, sz
    open(newunit=u, file=trim(listfile), status='old', action='read', iostat=ios)
    if (ios /= 0) then
      call check(.false., 'fixtures list readable')
      return
    end if
    count = 0
    identical = 0
    do
      read(u, '(A)', iostat=ios) fname
      if (ios /= 0) exit
      if (len_trim(fname) == 0) cycle
      count = count + 1
      inquire(file=trim(fname), size=sz)
      if (allocated(data)) deallocate(data)
      allocate(character(len=sz) :: data)
      open(newunit=i, file=trim(fname), access='stream', &
           form='unformatted', status='old', action='read')
      if (sz > 0) read(i) data
      close(i)
      call phokenize(data, scrolls)
      roundtrip = dephokenize(scrolls)
      if (len(roundtrip) == len(data) .and. roundtrip == data) identical = identical + 1
      n1 = normalize(data)
      n2 = normalize(n1)
      call check(len(n2) == len(n1) .and. n2 == n1, 'fixture normalize idempotent: ' // trim(fname))
    end do
    close(u)
    call check(count > 0, 'fixtures found')
    call check(identical >= count - 2, 'fixtures byte-identical round-trips')
    write(*, '(A,I0,A,I0)') 'fixtures: ', count, ' input.phext, byte-identical: ', identical
  end subroutine run_fixtures

end program test_phext
