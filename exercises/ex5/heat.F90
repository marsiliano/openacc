!  2D heat equation
!
!  Copyright (C) 2014  CSC - IT Center for Science Ltd.
!
!  Licensed under the terms of the GNU General Public License as published by
!  the Free Software Foundation, either version 3 of the License, or
!  (at your option) any later version.
!
!  Code is distributed in the hope that it will be useful,
!  but WITHOUT ANY WARRANTY; without even the implied warranty of
!  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!  GNU General Public License for more details.
!
!  Copy of the GNU General Public License can be onbtained from
!  see <http://www.gnu.org/licenses/>.

module heat
  implicit none

  integer, parameter :: dp = SELECTED_REAL_KIND(12)

  real(kind=dp), parameter :: DX = 0.01, DY = 0.01  ! Fixed grid spacing

  type :: field
     integer :: nx
     integer :: ny
     real(kind=dp) :: dx
     real(kind=dp) :: dy
     real(kind=dp) :: dx2
     real(kind=dp) :: dy2
     real(kind=dp), dimension(:,:), pointer, contiguous :: data
  end type field

contains

  ! Initialize the field type metadata
  ! Arguments:
  !   field0 (type(field)): input field
  !   nx, ny, dx, dy: field dimensions and spatial step size
  subroutine initialize_field_metadata(field0, nx, ny)
    implicit none

    type(field), intent(out) :: field0
    integer, intent(in) :: nx, ny

    field0%dx = DX
    field0%dy = DY
    field0%dx2 = DX**2
    field0%dy2 = DY**2
    field0%nx = nx
    field0%ny = ny
  end subroutine initialize_field_metadata

  ! Initialize the temperature field.  Pattern is disc with a radius 
  ! of nx_full / 6 in the center of the grid.
  ! Boundary conditions are (different) constant temperatures outside the grid
  subroutine initialize(field0)
    implicit none

    type(field), intent(inout) :: field0

    real(kind=dp) :: radius2
    integer :: i, j, ds2

    ! The arrays for field contain also a halo region
    allocate(field0%data(0:field0%nx+1, 0:field0%ny+1))

    ! Square of the disk radius
    radius2 = (field0%nx / 6.0)**2

    do j=0, field0%ny+1
       do i=0, field0%nx+1
          ds2 = (i - field0%nx / 2.0 + 1)**2 + &
               (j - field0%ny / 2.0 + 1)**2
          if (ds2 < radius2) then
             field0%data(i,j) = 5.0
          else
             field0%data(i,j) = 65.0
          end if
       end do
    end do

    ! Boundary conditions
    field0%data(:,0) = 20.0_dp
    field0%data(:,field0%ny+1) = 70.0_dp
    field0%data(0,:) = 85.0_dp
    field0%data(field0%nx+1,:) = 5.0_dp

  end subroutine initialize

  ! Swap the data fields of two variables of type field
  ! Arguments:
  !   curr, prev (type(field)): the two variables that are swapped
  subroutine swap_fields(curr, prev)
    implicit none

    type(field) :: curr, prev
    real(kind=dp), pointer, contiguous, dimension(:,:) :: tmp
    integer :: i, j

    ! Note: the data is kept fully on the device during computation
    tmp => curr % data
    curr % data => prev % data
    prev % data => tmp
  end subroutine swap_fields

  ! Copy the data from one field to another
  ! Arguments:
  !   from_field (type(field)): variable to copy from
  !   to_field (type(field)): variable to copy to
  subroutine copy_fields(from_field, to_field)
    implicit none

    type(field), intent(in) :: from_field
    type(field), intent(out) :: to_field

    ! Consistency checks
    if (.not. associated(from_field%data)) then
       write (*,*) "Can not copy from a field without allocated data"
       stop
    end if
    if (.not. associated(to_field%data)) then
       ! Target is not initialize, allocate memory
       allocate(to_field%data(lbound(from_field%data,1):ubound(from_field%data,1), &
            & lbound(from_field%data,2):ubound(from_field%data,2)))
    else if (any(shape(from_field%data) /= shape(to_field%data))) then
       write (*,*) "Wrong field data sizes in copy routine"
       print *, shape(from_field%data), shape(to_field%data)
       stop
    end if

    to_field%data = from_field%data

    to_field%nx = from_field%nx
    to_field%ny = from_field%ny
    to_field%dx = from_field%dx
    to_field%dy = from_field%dy
    to_field%dx2 = from_field%dx2
    to_field%dy2 = from_field%dy2
  end subroutine copy_fields

  ! Compute one time step of temperature evolution
  ! Arguments:
  !   curr (type(field)): current temperature values
  !   prev (type(field)): values from previous time step
  !   a (real(dp)): update equation constant
  !   dt (real(dp)): time step value
  subroutine evolve(curr, prev, a, dt)
    implicit none

    type(field), intent(inout) :: curr, prev
    real(kind=dp) :: a, dt
    real(kind=dp) :: dx2, dy2
    integer :: i, j, nx, ny, allocstat

    ! Variables for memory access outside of a type
    real(kind=dp), pointer, contiguous :: cdata(:,:), pdata(:,:)

    ! HINT: to help the compiler do not access 
    ! type components within OpenACC parallel regions
    nx = curr%nx
    ny = curr%ny
    dx2 = curr % dx2
    dy2 = curr % dy2
    cdata => curr % data
    pdata => prev % data
    
    ! TODO: Implement computation on device with OpenACC
    do j=1,ny
       do i=1,nx
          cdata(i, j) = pdata(i, j) + a * dt * &
               & ((pdata(i-1, j) - real(2, dp)*pdata(i, j) + &
               &   pdata(i+1, j)) / dx2 + &
               &  (pdata(i, j-1) - real(2, dp)*pdata(i, j) + &
               &   pdata(i, j+1)) / dy2)
       end do
    end do
  end subroutine evolve

  ! Output routine, saves the temperature distribution as a png image
  ! Arguments:
  !   curr (type(field)): variable with the temperature data
  !   iter (integer): index of the time step
  subroutine output(curr, iter)
    use, intrinsic :: ISO_C_BINDING
    implicit none

    type(field), intent(in) :: curr
    integer, intent(in) :: iter

    character(len=85) :: filename

    ! Interface for save_png C-function
    interface
       ! The C-function definition is
       !   int save_png(double *data,
       !                const int nx, const int ny,
       !                const char *fname, const char lang)
       function save_png(data, nx, ny, fname, lang) &
            & bind(C,name="save_png") result(stat)
         use, intrinsic :: ISO_C_BINDING
         implicit none
         real(kind=C_DOUBLE) :: data(*)
         integer(kind=C_INT), value, intent(IN) :: nx, ny
         character(kind=C_CHAR), intent(IN) :: fname(*)
         character(kind=C_CHAR), value, intent(IN) :: lang
         integer(kind=C_INT) :: stat
       end function save_png
    end interface   

    ! The actual write routine takes only the actual data
    ! (without ghost layers) so we need array for that
    integer :: nx, ny, stat
    real(kind=dp), pointer, contiguous :: cdata(:,:)
    
    cdata => curr % data
 
    nx = curr%nx
    ny = curr%ny

    write(filename,'(A5,I5.5,A4,A)')  'heat_', iter, '.png'
    stat = save_png(cdata(1:nx,1:ny), nx, ny, &
         & trim(filename) // C_NULL_CHAR, 'F')
  end subroutine output

  ! Clean up routine for field type
  ! Arguments:
  !   field0 (type(field)): field variable to be cleared
  subroutine finalize(field0)
    implicit none

    type(field), intent(inout) :: field0

    deallocate(field0%data)
  end subroutine finalize

  ! Reads the temperature distribution from an input file
  ! Arguments:
  !   field0 (type(field)): field variable that will store the
  !                         read data
  !   filename (char): name of the input file
  ! Note that this version assumes the input data to be in C memory layout
  subroutine read_input(field0, filename)
    implicit none

    type(field), intent(out) :: field0
    character(len=85), intent(in) :: filename

    integer :: nx, ny, i
    character(len=2) :: dummy

    open(10, file=filename)
    ! Read the header
    read(10, *) dummy, nx, ny ! nx is the number of rows

    call initialize_field_metadata(field0, nx, ny)
    ! The arrays for temperature field contain also a halo region
    allocate(field0%data(0:field0%nx+1, 0:field0%ny+1))

    ! Read the data
    do i = 1, nx
       read(10, *) field0%data(i, 1:ny)
    end do

    ! Set the boundary values
    field0%data(1:nx,   0     ) = field0%data(1:nx, 1     )
    field0%data(1:nx,     ny+1) = field0%data(1:nx,   ny  )
    field0%data(0,      0:ny+1) = field0%data(1,    0:ny+1)
    field0%data(  nx+1, 0:ny+1) = field0%data(  nx, 0:ny+1)

    close(10)
  end subroutine read_input

end module heat
