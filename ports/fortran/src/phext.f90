! phext.f90 - libphext port for Fortran (0.6.1 parity semantics; normative
! reference: libphext-py). Phext is a 9-dimensional plain-text format:
! scrolls of text addressed by a coordinate, separated in the byte stream
! by dimension-break bytes.
!
! Dimension breaks (dimension index -> byte):
!   0 library 0x01, 1 shelf 0x1F, 2 series 0x1E, 3 collection 0x1D,
!   4 volume 0x1C, 5 book 0x1A, 6 chapter 0x19, 7 section 0x18,
!   8 scroll 0x17.
! A break at dimension d increments component d and resets all lower
! components to 1. Scroll text is a maximal run of non-break bytes; the
! newline byte 0x0A is ordinary text, NOT a break. Buffers are Fortran
! character strings used as byte strings (lengths always explicit via
! len()); no encoding is ever interpreted.
module phext_mod
  implicit none
  private

  public :: scroll_t
  public :: parse_coordinate, format_coordinate, compare_coords
  public :: phokenize, dephokenize, normalize, fetch
  public :: insert, replace, remove, explode, implode
  public :: break_byte

  type :: scroll_t
    integer :: coord(9) = 1
    character(len=:), allocatable :: text
  end type scroll_t

  ! dimension index 0..8 -> break byte value
  integer, parameter :: BREAKS(0:8) = [1, 31, 30, 29, 28, 26, 25, 24, 23]

contains

  integer function break_byte(dim)
    integer, intent(in) :: dim
    break_byte = BREAKS(dim)
  end function break_byte

  ! dimension index for a byte value, or -1 when it is not a break
  integer function break_dim(byteval)
    integer, intent(in) :: byteval
    integer :: d
    break_dim = -1
    do d = 0, 8
      if (BREAKS(d) == byteval) then
        break_dim = d
        return
      end if
    end do
  end function break_dim

  ! Parse "a.b.c/d.e.f/g.h.i"; ok=.false. unless 9 components each >= 1.
  subroutine parse_coordinate(str, coord, ok)
    character(len=*), intent(in) :: str
    integer, intent(out) :: coord(9)
    logical, intent(out) :: ok
    integer :: i, j, ncomp, val, start
    character(len=:), allocatable :: s
    ok = .false.
    coord = 1
    s = trim(str)
    ncomp = 0
    val = 0
    start = 1
    do i = 1, len(s) + 1
      if (i == len(s) + 1 .or. s(i:i) == '.' .or. s(i:i) == '/') then
        if (i == start) return              ! empty component
        val = 0
        do j = start, i - 1
          if (s(j:j) < '0' .or. s(j:j) > '9') return
          val = val * 10 + (iachar(s(j:j)) - iachar('0'))
        end do
        if (val < 1) return
        ncomp = ncomp + 1
        if (ncomp > 9) return
        coord(ncomp) = val
        start = i + 1
      end if
    end do
    if (ncomp /= 9) return
    ok = .true.
  end subroutine parse_coordinate

  function format_coordinate(coord) result(str)
    integer, intent(in) :: coord(9)
    character(len=:), allocatable :: str
    character(len=32) :: tmp
    integer :: i
    str = ''
    do i = 1, 9
      write(tmp, '(I0)') coord(i)
      str = str // trim(tmp)
      if (i == 3 .or. i == 6) then
        str = str // '/'
      else if (i < 9) then
        str = str // '.'
      end if
    end do
  end function format_coordinate

  ! Lexicographic comparison: -1, 0, 1
  integer function compare_coords(a, b)
    integer, intent(in) :: a(9), b(9)
    integer :: i
    compare_coords = 0
    do i = 1, 9
      if (a(i) < b(i)) then
        compare_coords = -1
        return
      else if (a(i) > b(i)) then
        compare_coords = 1
        return
      end if
    end do
  end function compare_coords

  subroutine apply_break(coord, dim)
    integer, intent(inout) :: coord(9)
    integer, intent(in) :: dim        ! 0-based dimension
    integer :: j
    coord(dim + 1) = coord(dim + 1) + 1
    do j = dim + 2, 9
      coord(j) = 1
    end do
  end subroutine apply_break

  ! Split a buffer into its ordered scrolls.
  subroutine phokenize(buffer, scrolls)
    character(len=*), intent(in) :: buffer
    type(scroll_t), allocatable, intent(out) :: scrolls(:)
    integer :: i, n, count, start, d
    integer :: walker(9)
    n = len(buffer)
    count = 0
    i = 1
    do while (i <= n)
      if (break_dim(iachar(buffer(i:i))) >= 0) then
        i = i + 1
      else
        count = count + 1
        do while (i <= n .and. break_dim(iachar(buffer(i:i))) < 0)
          i = i + 1
        end do
      end if
    end do
    allocate(scrolls(count))
    walker = 1
    count = 0
    i = 1
    do while (i <= n)
      d = break_dim(iachar(buffer(i:i)))
      if (d >= 0) then
        call apply_break(walker, d)
        i = i + 1
      else
        start = i
        do while (i <= n .and. break_dim(iachar(buffer(i:i))) < 0)
          i = i + 1
        end do
        count = count + 1
        scrolls(count)%coord = walker
        scrolls(count)%text = buffer(start:i - 1)
      end if
    end do
  end subroutine phokenize

  ! Append the break bytes that move loc up to target; loc updated.
  subroutine advance(loc, target, out, outlen)
    integer, intent(inout) :: loc(9)
    integer, intent(in) :: target(9)
    character(len=:), allocatable, intent(inout) :: out
    integer, intent(inout) :: outlen
    integer :: d, j, k, reached(9)
    if (compare_coords(loc, target) >= 0) return
    d = 0
    do while (loc(d + 1) == target(d + 1))
      d = d + 1
    end do
    do k = 1, target(d + 1) - loc(d + 1)
      call push_byte(out, outlen, BREAKS(d))
    end do
    reached = loc
    reached(d + 1) = target(d + 1)
    do j = d + 2, 9
      reached(j) = 1
    end do
    do j = d + 1, 8
      do k = 1, target(j + 1) - 1
        call push_byte(out, outlen, BREAKS(j))
      end do
      reached(j + 1) = target(j + 1)
    end do
    loc = reached
  end subroutine advance

  subroutine push_byte(buf, buflen, byteval)
    character(len=:), allocatable, intent(inout) :: buf
    integer, intent(inout) :: buflen
    integer, intent(in) :: byteval
    character(len=:), allocatable :: grown
    if (.not. allocated(buf)) then
      allocate(character(len=256) :: buf)
      buflen = 0
    end if
    if (buflen == len(buf)) then
      allocate(character(len=len(buf) * 2) :: grown)
      grown(1:buflen) = buf(1:buflen)
      call move_alloc(grown, buf)
    end if
    buflen = buflen + 1
    buf(buflen:buflen) = achar(byteval)
  end subroutine push_byte

  subroutine push_text(buf, buflen, text)
    character(len=:), allocatable, intent(inout) :: buf
    integer, intent(inout) :: buflen
    character(len=*), intent(in) :: text
    integer :: i
    do i = 1, len(text)
      call push_byte(buf, buflen, iachar(text(i:i)))
    end do
  end subroutine push_text

  ! Serialize scrolls (ascending order, as phokenize yields) into
  ! canonical phext bytes, advancing from 1.1.1/1.1.1/1.1.1.
  function dephokenize(scrolls) result(outstr)
    type(scroll_t), intent(in) :: scrolls(:)
    character(len=:), allocatable :: outstr
    character(len=:), allocatable :: buf
    integer :: buflen, i, loc(9)
    allocate(character(len=256) :: buf)
    buflen = 0
    loc = 1
    do i = 1, size(scrolls)
      call advance(loc, scrolls(i)%coord, buf, buflen)
      call push_text(buf, buflen, scrolls(i)%text)
    end do
    if (buflen == 0) then
      outstr = ''
    else
      outstr = buf(1:buflen)
    end if
  end function dephokenize

  function normalize(buffer) result(outstr)
    character(len=*), intent(in) :: buffer
    character(len=:), allocatable :: outstr
    type(scroll_t), allocatable :: scrolls(:)
    call phokenize(buffer, scrolls)
    outstr = dephokenize(scrolls)
  end function normalize

  ! Text at coord, or "" for a gap coordinate (never a control byte).
  function fetch(buffer, coord) result(text)
    character(len=*), intent(in) :: buffer
    integer, intent(in) :: coord(9)
    character(len=:), allocatable :: text
    type(scroll_t), allocatable :: scrolls(:)
    integer :: i
    text = ''
    call phokenize(buffer, scrolls)
    do i = 1, size(scrolls)
      if (compare_coords(scrolls(i)%coord, coord) == 0) then
        text = scrolls(i)%text
        return
      end if
    end do
  end function fetch

  function update(buffer, coord, text, overwrite) result(outstr)
    character(len=*), intent(in) :: buffer, text
    integer, intent(in) :: coord(9)
    logical, intent(in) :: overwrite
    character(len=:), allocatable :: outstr
    type(scroll_t), allocatable :: items(:), result(:)
    integer :: i, nres
    logical :: appended
    call phokenize(buffer, items)
    allocate(result(size(items) + 1))
    nres = 0
    appended = .false.
    do i = 1, size(items)
      if (.not. appended .and. compare_coords(items(i)%coord, coord) > 0) then
        nres = nres + 1
        result(nres)%coord = coord
        result(nres)%text = text
        appended = .true.
      end if
      if (.not. appended .and. compare_coords(items(i)%coord, coord) == 0) then
        nres = nres + 1
        result(nres)%coord = coord
        if (overwrite) then
          result(nres)%text = text
        else
          result(nres)%text = items(i)%text // text
        end if
        appended = .true.
        cycle
      end if
      nres = nres + 1
      result(nres) = items(i)
    end do
    if (.not. appended) then
      nres = nres + 1
      result(nres)%coord = coord
      result(nres)%text = text
    end if
    outstr = dephokenize(result(1:nres))
  end function update

  ! Insert: existing scroll at coord becomes existing + inserted.
  function insert(buffer, coord, text) result(outstr)
    character(len=*), intent(in) :: buffer, text
    integer, intent(in) :: coord(9)
    character(len=:), allocatable :: outstr
    outstr = update(buffer, coord, text, .false.)
  end function insert

  ! Replace: overwrite the scroll at coord (creating it if absent).
  function replace(buffer, coord, text) result(outstr)
    character(len=*), intent(in) :: buffer, text
    integer, intent(in) :: coord(9)
    character(len=:), allocatable :: outstr
    outstr = update(buffer, coord, text, .true.)
  end function replace

  ! Remove: replace with "" then normalize.
  function remove(buffer, coord) result(outstr)
    character(len=*), intent(in) :: buffer
    integer, intent(in) :: coord(9)
    character(len=:), allocatable :: outstr
    outstr = normalize(update(buffer, coord, '', .true.))
  end function remove

  ! Explode: the map form of phokenize. In Fortran idiom the "map" is the
  ! scroll array itself: coordinates are the keys, in ascending order.
  subroutine explode(buffer, scrolls)
    character(len=*), intent(in) :: buffer
    type(scroll_t), allocatable, intent(out) :: scrolls(:)
    call phokenize(buffer, scrolls)
  end subroutine explode

  ! Implode: the map form of dephokenize. Sorts a copy of the scroll
  ! array into ascending coordinate order, then serializes.
  function implode(scrolls_in) result(outstr)
    type(scroll_t), intent(in) :: scrolls_in(:)
    character(len=:), allocatable :: outstr
    type(scroll_t), allocatable :: scrolls(:)
    type(scroll_t) :: tmp
    integer :: i, j
    allocate(scrolls, source=scrolls_in)
    do i = 2, size(scrolls)
      tmp = scrolls(i)
      j = i - 1
      do while (j >= 1 .and. compare_coords(scrolls(j)%coord, tmp%coord) > 0)
        scrolls(j + 1) = scrolls(j)
        j = j - 1
      end do
      scrolls(j + 1) = tmp
    end do
    outstr = dephokenize(scrolls)
  end function implode

end module phext_mod
