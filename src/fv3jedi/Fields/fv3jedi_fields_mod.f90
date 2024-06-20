! (C) Copyright 2020 UCAR
!
! This software is licensed under the terms of the Apache Licence Version 2.0
! which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.

module fv3jedi_fields_mod

! atlas
use atlas_module, only: atlas_field, atlas_fieldset, atlas_real, atlas_metadata

! fckit
use fckit_mpi_module
use fckit_configuration_module

! oops
use datetime_mod
use missing_values_mod
use oops_variables_mod
use string_utils

! fv3jedi
use fv3jedi_field_mod,         only: fv3jedi_field, field_clen, checksame, get_field, put_field, &
                                     hasfield, create_field
use fv3jedi_geom_mod,          only: fv3jedi_geom
use fv3jedi_interpolation_mod, only: field2field_interp
use fv3jedi_kinds_mod,         only: kind_real
use fields_metadata_mod,       only: field_metadata
use wind_vt_mod,               only: a_to_d

use mpp_domains_mod, only: mpp_update_domains, mpp_update_domains_ad

implicit none
private
public :: fv3jedi_fields

! --------------------------------------------------------------------------------------------------

! Fields type (base for State and Increment)
type :: fv3jedi_fields

  integer :: isc, iec, jsc, jec, npx, npy, npz, nf             ! Geometry convenience
  type(fckit_mpi_comm) :: f_comm                               ! Communicator
  type(fv3jedi_field), allocatable :: fields(:)                ! Array of fields
  type(datetime) :: time
  integer :: ntracers

  integer :: ninterface_specific
  ! Whether to update interface-specific fields from generic jedi fields before passing to the
  ! model, for example
  logical :: interface_fields_are_out_of_date

  contains

    ! Methods needed by both state and increment classes
    procedure, public :: create
    procedure, public :: delete
    procedure, public :: copy
    procedure, public :: zero
    procedure, public :: norm
    procedure, public :: change_resol
    procedure, public :: change_resol_ad
    procedure, public :: minmaxrms
    procedure, public :: accumul
    procedure, public :: serialize
    procedure, public :: serializeSect
    procedure, public :: deserialize
    procedure, public :: to_fieldset
    procedure, public :: from_fieldset
    procedure, public :: update_fields
    procedure, public :: synchronize_interface_fields  ! Update inteface-specific fields

    ! Public array/field accessor functions
    procedure, public :: has_field => has_field_
    generic,   public :: get_field => get_field_return_type_pointer, &
                                      get_field_return_array_pointer, &
                                      get_field_return_array_allocatable
    procedure, public :: put_field => put_field_

    ! Private array/field accessor functions
    procedure, private :: get_field_return_type_pointer
    procedure, private :: get_field_return_array_pointer
    procedure, private :: get_field_return_array_allocatable

endtype fv3jedi_fields

! --------------------------------------------------------------------------------------------------

contains

! --------------------------------------------------------------------------------------------------

subroutine create(self, geom, vars)

  class(fv3jedi_fields), intent(inout) :: self
  type(fv3jedi_geom),    intent(in)    :: geom
  type(oops_variables),  intent(in)    :: vars

  integer :: var, fc
  type(field_metadata) :: fmd
  logical :: field_fail

  ! Count interface-specific fields in vars
  self%ninterface_specific = 0
  do var = 1, vars%nvars()
    fmd = geom%fmd%get_field_metadata(trim(vars%variable(var)))
    if (fmd%interface_specific) then
      self%ninterface_specific = self%ninterface_specific + 1
    end if
  end do
  self%interface_fields_are_out_of_date = .false.

  ! Allocate fields structure
  ! -------------------------
  self%nf = vars%nvars()
  allocate(self%fields(self%nf))

  ! Loop through and allocate actual fields
  ! ---------------------------------------
  fc = 0
  self%ntracers = 0
  do var = 1, vars%nvars()

    ! Uptick counter
    fc=fc+1;

    ! Copy geometry
    self%fields(fc)%isc = geom%isc
    self%fields(fc)%iec = geom%iec
    self%fields(fc)%jsc = geom%jsc
    self%fields(fc)%jec = geom%jec

    write(6,*) 'creating field ',trim(vars%variable(var)),geom%isc,geom%iec,geom%jsc,geom%jec
    ! Set this fields meta data
    call create_field(self%fields(fc), geom%fmd%get_field_metadata(trim(vars%variable(var))), &
                      geom%f_comm)

    ! count number of tracers using tracer flag
    if (self%fields(fc)%tracer) then
      self%ntracers = self%ntracers + 1
    end if
  enddo

  ! Check field count
  if (fc .ne. self%nf) call abor1_ftn("fv3jedi_fields_mod.create: fc does not equal self%nf")

  ! Initialize all arrays to zero
  call self%zero()

  ! Copy some geometry for convenience
  self%isc    = geom%isc
  self%iec    = geom%iec
  self%jsc    = geom%jsc
  self%jec    = geom%jec
  self%npx    = geom%npx
  self%npy    = geom%npy
  self%npz    = geom%npz

  ! Pointer to fv3jedi communicator
  self%f_comm = geom%f_comm

  ! Check winds
  field_fail = self%has_field('ua') .and. .not.self%has_field('va')
  if (field_fail) call abor1_ftn("fv3jedi_fields.create: found A-Grid u but not v")
  field_fail = .not.self%has_field('ua') .and. self%has_field('va')
  if (field_fail) call abor1_ftn("fv3jedi_fields.create: found A-Grid v but not u")
  field_fail = self%has_field('ud') .and. .not.self%has_field('vd')
  if (field_fail) call abor1_ftn("fv3jedi_fields.create: found D-Grid u but not v")
  field_fail = .not.self%has_field('ud') .and. self%has_field('vd')
  if (field_fail) call abor1_ftn("fv3jedi_fields.create: found D-Grid v but not u")

  !Check User's choice of ozone variables.
  field_fail = self%has_field('o3mr') .and. self%has_field('o3ppmv')
  if (field_fail) call abor1_ftn("fv3jedi_fields.create: o3mr and o3ppmv created")

end subroutine create

! --------------------------------------------------------------------------------------------------

subroutine delete(self)

class(fv3jedi_fields), intent(inout) :: self

integer :: var

do var = 1, size(self%fields)
  if (self%fields(var)%lalloc) deallocate(self%fields(var)%array)
enddo
deallocate(self%fields)

end subroutine delete

! --------------------------------------------------------------------------------------------------

subroutine copy(self, other)

class(fv3jedi_fields), intent(inout) :: self
class(fv3jedi_fields),  intent(in)    :: other

integer :: var

call checksame(self%fields, other%fields, "fv3jedi_fields_mod.copy")

do var = 1, self%nf
  self%fields(var)%array = other%fields(var)%array
enddo

self%ntracers = other%ntracers
self%interface_fields_are_out_of_date = other%interface_fields_are_out_of_date

end subroutine copy

! --------------------------------------------------------------------------------------------------

subroutine zero(self)

class(fv3jedi_fields), intent(inout) :: self

integer :: var

do var = 1, self%nf
  self%fields(var)%array = 0.0_kind_real
enddo
self%interface_fields_are_out_of_date = .false.

endsubroutine zero

! --------------------------------------------------------------------------------------------------

subroutine norm(self, normout)

class(fv3jedi_fields), intent(inout) :: self
real(kind=kind_real),  intent(out)   :: normout

integer :: i, j, k, ii, iisum, var
real(kind=kind_real) :: zz

if (self%ninterface_specific > 0 .and. self%interface_fields_are_out_of_date) then
  call abor1_ftn("fv3jedi_fields_mod.norm: interface-specific fields are out of date; update&
                 & before calling subroutine norm")
end if

zz = 0.0_kind_real
ii = 0

do var = 1, self%nf

  do k = 1, self%fields(var)%npz
    do j = self%fields(var)%jsc, self%fields(var)%jec
      do i = self%fields(var)%isc, self%fields(var)%iec
        if (self%fields(var)%array(i,j,k)/=missing_value(0.0_kind_real)) then
           zz = zz + self%fields(var)%array(i,j,k)**2
           ii = ii + 1
        endif
      enddo
    enddo
  enddo

enddo

!Get global values
call self%f_comm%allreduce(zz,normout,fckit_mpi_sum())
call self%f_comm%allreduce(ii,iisum,fckit_mpi_sum())
normout = sqrt(normout/real(iisum,kind_real))

endsubroutine norm

! --------------------------------------------------------------------------------------------------

subroutine change_resol(self, geom, other, geom_other)

implicit none
class(fv3jedi_fields), intent(inout) :: self
type(fv3jedi_geom),    intent(inout) :: geom
class(fv3jedi_fields), intent(in)    :: other
type(fv3jedi_geom),    intent(inout) :: geom_other

! Interpolation
integer :: var
type(field2field_interp) :: interp
logical :: integer_interp = .false.

call checksame(self%fields, other%fields, "fv3jedi_fields_mod.change_resol")

if ((other%iec-other%isc+1)-(self%iec-self%isc+1) == 0 .AND. &
     geom%stretch_fac == geom_other%stretch_fac .AND. &
     geom%target_lat == geom_other%target_lat .AND. &
     geom%target_lon == geom_other%target_lon) then

     call self%copy(other)

else

  ! Check if integer interp needed
  do var = 1, self%nf
    if (trim(other%fields(var)%interpolation_type) == "integer") integer_interp = .true.
  enddo

  call interp%create(geom%interp_method, integer_interp, geom_other, geom)
  call interp%apply(self%nf, geom_other, other%fields, geom, self%fields)
  call interp%delete()

  ! Flag fields as out-of-date in anticipation of upcoming code change making interpolator generic,
  ! so that it would no longer act on interface-specific fields. Today this out-of-date flag is not
  ! needed, but by putting it in now we can anticipate synchronizations needed after this change.
  ! TODO(FH) make this interpolator change!
  if (self%ninterface_specific > 0) then
    self%interface_fields_are_out_of_date = .true.
  end if

endif

end subroutine change_resol

! --------------------------------------------------------------------------------------------------

subroutine change_resol_ad(self, geom, other, geom_other)

implicit none
class(fv3jedi_fields), intent(inout) :: self       ! Target fields
type(fv3jedi_geom),    intent(in)    :: geom       ! Target geometry
class(fv3jedi_fields), intent(in)    :: other      ! Source fields
type(fv3jedi_geom),    intent(in)    :: geom_other ! Source geometry

integer                  :: var
type(field2field_interp) :: interp
logical                  :: integer_interp = .false.

call checksame(self%fields, other%fields, "fv3jedi_fields_mod.change_resol_ad")

if ((other%iec - other%isc + 1) - (self%iec - self%isc + 1) == 0 .AND. &
  geom%stretch_fac == geom_other%stretch_fac .AND. &
  geom%target_lat == geom_other%target_lat .AND. &
  geom%target_lon == geom_other%target_lon) then
  call self%copy(other)
else
  do var = 1, self%nf
    if (trim(other%fields(var)%interpolation_type) == "integer") integer_interp = .true.
  enddo
  call interp%create(geom_other%interp_method, integer_interp, geom, geom_other)
  call interp%apply_ad(self%nf, geom, self%fields, geom_other, other%fields)
  call interp%delete()
endif

end subroutine change_resol_ad

! --------------------------------------------------------------------------------------------------

subroutine minmaxrms(self, field_num, field_name, minmaxrmsout)

class(fv3jedi_fields), intent(inout) :: self
integer,               intent(in)    :: field_num
character(len=*),      intent(inout) :: field_name
real(kind=kind_real),  intent(out)   :: minmaxrmsout(3)

integer :: isc, iec, jsc, jec, npz
real(kind=kind_real) :: tmp(3), gs3, gs3g

! Subroutine minmaxrms is used for prints -- allow fields to be out of date to avoid excessive
! synchronizations for minimal scientific gain
!if (self%ninterface_specific > 0 .and. self%interface_fields_are_out_of_date) then
!  call abor1_ftn("fv3jedi_fields_mod.minmaxrms: interface-specific fields are out of date; update&
!                 & before calling subroutine minmaxrms")
!end if

isc = self%fields(field_num)%isc
iec = self%fields(field_num)%iec
jsc = self%fields(field_num)%jsc
jec = self%fields(field_num)%jec
npz = self%fields(field_num)%npz

field_name = self%fields(field_num)%long_name

! Compute global sum over the field
gs3 = real((iec-isc+1)*(jec-jsc+1)*npz, kind_real)
call self%f_comm%allreduce(gs3,gs3g,fckit_mpi_sum())

! Min/Max/SumSquares
tmp(1) = minval(self%fields(field_num)%array(isc:iec,jsc:jec,1:npz), &
 & mask=self%fields(field_num)%array(isc:iec,jsc:jec,1:npz)/=missing_value(0.0_kind_real))
tmp(2) = maxval(self%fields(field_num)%array(isc:iec,jsc:jec,1:npz), &
 & mask=self%fields(field_num)%array(isc:iec,jsc:jec,1:npz)/=missing_value(0.0_kind_real))
tmp(3) =    sum(self%fields(field_num)%array(isc:iec,jsc:jec,1:npz)**2, &
 & mask=self%fields(field_num)%array(isc:iec,jsc:jec,1:npz)/=missing_value(0.0_kind_real))

! Get global min/max/sum
call self%f_comm%allreduce(tmp(1), minmaxrmsout(1), fckit_mpi_min())
call self%f_comm%allreduce(tmp(2), minmaxrmsout(2), fckit_mpi_max())
call self%f_comm%allreduce(tmp(3), minmaxrmsout(3), fckit_mpi_sum())

! SumSquares to rms
minmaxrmsout(3) = sqrt(minmaxrmsout(3)/gs3g)

endsubroutine minmaxrms

! --------------------------------------------------------------------------------------------------

subroutine accumul(self, zz, rhs)

implicit none
class(fv3jedi_fields), intent(inout) :: self
real(kind=kind_real),  intent(in)    :: zz
class(fv3jedi_fields), intent(in)    :: rhs

integer :: var

call checksame(self%fields,rhs%fields,"fv3jedi_fields.accumul")

do var = 1, self%nf
  self%fields(var)%array = self%fields(var)%array + zz * rhs%fields(var)%array
enddo

! Set out-of-date if rhs is out-of-date
if (self%ninterface_specific > 0) then
  if (rhs%interface_fields_are_out_of_date) self%interface_fields_are_out_of_date = .true.
end if

end subroutine accumul

! --------------------------------------------------------------------------------------------------

subroutine serializeSect(self,vsize,isc,iec,jsc,jec,vect_inc)

implicit none

! Passed variables
class(fv3jedi_fields), intent(in)  :: self
integer,               intent(in)  :: vsize
integer,               intent(in)  :: isc
integer,               intent(in)  :: iec
integer,               intent(in)  :: jsc
integer,               intent(in)  :: jec
real(kind_real),       intent(out) :: vect_inc(vsize)

! Local variables
integer :: ind, var, i, j, k

write(6,*) 'HEYYY start of serializeSect vsize is ',vsize,isc,iec,jsc,jec
! Initialize
ind = 0
! Copy
write(6,*) 'indices are ',isc,iec,jsc,jec,self%fields(var)%npz,self%nf
do var = 1, self%nf
  write(6,*) 'copying fields from ',isc,iec,jsc,jec,self%fields(var)%npz,self%nf,ind,var
  write(6,*) 'about to look at val from ',iec,jec,self%fields(var)%npz,trim(self%fields(var)%short_name)
  write(6,*) 'array val is ',self%fields(var)%array(isc, jsc, self%fields(var)%npz )
  write(6,*) 'array val is ',self%fields(var)%array(iec, jec, self%fields(var)%npz )
  do k = 1,self%fields(var)%npz
    do j = jsc,jec
      do i = isc,iec
        ind = ind + 1
        vect_inc(ind) = self%fields(var)%array(i, j, k)
      enddo
    enddo
  enddo
enddo
write(6,*) 'HEYYY serializeSect number of fields is ',self%nf,' ind is ',ind, 'vsize ',size(vect_inc)

end subroutine serializeSect

! --------------------------------------------------------------------------------------------------
subroutine serialize(self,vsize,vect_inc)

implicit none

! Passed variables
class(fv3jedi_fields), intent(in)  :: self
integer,               intent(in)  :: vsize
real(kind_real),       intent(out) :: vect_inc(vsize)

! Local variables
integer :: ind, var, i, j, k

! Initialize
ind = 0

! Copy
do var = 1, self%nf
  do k = 1,self%fields(var)%npz
    do j = self%fields(var)%jsc,self%fields(var)%jec
      do i = self%fields(var)%isc,self%fields(var)%iec
        ind = ind + 1
        vect_inc(ind) = self%fields(var)%array(i, j, k)
      enddo
    enddo
  enddo
enddo

end subroutine serialize

! --------------------------------------------------------------------------------------------------

subroutine deserialize(self, vsize, vect_inc, index)

implicit none

! Passed variables
class(fv3jedi_fields), intent(inout) :: self
integer,               intent(in) :: vsize
real(kind_real),       intent(in) :: vect_inc(vsize)
integer,               intent(inout) :: index

! Local variables
integer :: ind, var, i, j, k

write(6,*) 'HEY, in deserialize of fv3jedi_fields_mod'
! Copy
do var = 1, self%nf
  do k = 1,self%fields(var)%npz
    do j = self%fields(var)%jsc,self%fields(var)%jec
      do i = self%fields(var)%isc,self%fields(var)%iec
        self%fields(var)%array(i, j, k) = vect_inc(index + 1)
        index = index + 1
      enddo
    enddo
  enddo
enddo

end subroutine deserialize

! --------------------------------------------------------------------------------------------------

! Fills a FieldSet with model data, including halos
! - exchanges halo data between fv3 grid tiles
! - stores fv3-jedi field (local + halo) data in atlas FieldSet as 1d fields
subroutine to_fieldset(self, geom, vars, afieldset)

implicit none
class(fv3jedi_fields), intent(in)    :: self
type(fv3jedi_geom),    intent(in)    :: geom
type(oops_variables),  intent(in)    :: vars
type(atlas_fieldset),  intent(inout) :: afieldset

integer :: jvar, jl
type(fv3jedi_field), pointer :: field
real(kind=kind_real), pointer :: ptr(:,:)
type(atlas_field) :: afield
type(atlas_metadata) :: meta

! Variables needed to handle boundary-condition grid points in a regional grid
integer :: max_npz, ngrid, dummy_ntris, dummy_nquads
real(kind=kind_real), allocatable :: tmp(:,:,:)

! To allocate tmp just once, we need the max number of levels
max_npz = -1
do jvar = 1, vars%nvars()
  call self%get_field(trim(vars%variable(jvar)), field)
  max_npz = max(max_npz, field%npz)
end do

! Set up regional-grid variables
if (geom%ntiles == 1) then
  call geom%get_num_nodes_and_elements(ngrid, dummy_ntris, dummy_nquads)
  allocate(tmp(geom%isd:geom%ied, geom%jsd:geom%jed, max_npz))
end if

do jvar = 1, vars%nvars()

  ! Get field
  call self%get_field(trim(vars%variable(jvar)), field)
  if (field%interface_specific) then
    call abor1_ftn("fv3jedi_fields_mod.to_fieldset: interface-specific field requested")
  end if

  ! Sanity check
  if (trim(field%horizontal_stagger_location) .ne. 'center') then
    call abor1_ftn("to_fieldset: only cell-centered fields are supported in atlas interface to OOPS")
  end if

  ! Get/create atlas field
  if (afieldset%has_field(field%long_name)) then
    afield = afieldset%field(field%long_name)
  else
    afield = geom%afunctionspace%create_field( name=field%long_name, &
                                               kind=atlas_real(kind_real), &
                                               levels=field%npz )
    call afieldset%add(afield)
  endif

  ! Copy fv3-jedi's owned field data into atlas field
  ! - For a global model, this is easy: copy the owned data.
  ! - For a regional model, extra steps are needed because atlas and fv3 have different definitions
  !   of the halo. The boundary condition points that surround a regional grid are halos in fv3,
  !   but they are "owned" boundary condition points in atlas. Here we're trying to fill the owned
  !   data for atlas, so the regional cases has to copy the fv3 owned data AND some fv3 halo data
  !   from the boundary condition regions into the atlas array.
  ! In both cases, atlas fills its halo (internal boundaries) by a halo exchange in the C++ layer.
  ! This could be replaced with a copy from the fv3jedi data IF we manually imported the halo
  ! structure from fv3jedi into atlas, instead of the current solution of allowing atlas to
  ! automatically generate the halo from the connectivity.
  call afield%data(ptr)
  if (geom%ntiles == 6) then
    do jl=1, field%npz
      ptr(jl, 1:geom%ngrid) = reshape(field%array(:, :, jl), (/geom%ngrid/))
    end do
  else if (geom%ntiles == 1) then
    tmp = missing_value(0.0_kind_real)
    ! Fill the owned data at the center of the grid patch
    tmp(geom%isc:geom%iec, geom%jsc:geom%jec, 1:field%npz) = field%array(:, :, :)
    ! Use a halo-exchange to fill internal boundaries = ghost points (all 3 points deep)
    call mpp_update_domains(tmp, geom%domain, complete=.true.)
    ! Manually fill in external boundaries = boundary conditions (1 point deep, enough for atlas)
    ! Now that internal data and internal boundaries are filled, we can fill the external boundaries
    ! by simply copying the internal data across each external boundary. We do this horizontally
    ! then vertically, each time copying one point past the end of compute domain. This ensure that
    ! corners are copied across the external boundary too.
    ! TODO(): Long term, would be better to grab the actual BC's when running the model.
    if (self%isc == 1) then  ! left edge
      tmp(geom%isc-1, geom%jsc-1:geom%jec+1, 1:field%npz) = &
        tmp(geom%isc, geom%jsc-1:geom%jec+1, 1:field%npz)
    end if
    if (self%iec == self%npx-1) then  ! right edge
      tmp(geom%iec+1, geom%jsc-1:geom%jec+1, 1:field%npz) = &
        tmp(geom%iec, geom%jsc-1:geom%jec+1, 1:field%npz)
    end if
    if (self%jsc == 1) then  ! bottom edge
      tmp(geom%isc-1:geom%iec+1, geom%jsc-1, 1:field%npz) = &
        tmp(geom%isc-1:geom%iec+1, geom%jsc, 1:field%npz)
    end if
    if (self%jec == self%npy-1) then  ! top edge
      tmp(geom%isc-1:geom%iec+1, geom%jec+1, 1:field%npz) = &
        tmp(geom%isc-1:geom%iec+1, geom%jec, 1:field%npz)
    end if
    do jl=1, field%npz
      call geom%fv3_nodes_to_atlas_nodes(tmp(:, :, jl), ptr(jl, 1:ngrid))
    end do
  end if

  ! Set dirty: halo points are uninitialized and must be filled by calling the atlas haloExchange
  call afield%set_dirty(.true.)

  meta = afield%metadata()
  call meta%set('interp_type', trim(field%interpolation_type))

  ! Set atlas::Field metadata for interp mask IFF the user specifically requested a non-default mask
  if (trim(field%interpolation_source_point_mask) .ne. 'default') then
    call meta%set('interp_source_point_mask', trim(field%interpolation_source_point_mask))
  end if

  ! Release pointer
  call afield%final()

enddo

! Clean up
if (allocated(tmp)) deallocate(tmp)

end subroutine to_fieldset

! --------------------------------------------------------------------------------------------------

! Fills model data from an atlas FieldSet
! - copies local portion of packed (local + halo) data into fv3-jedi field
! - Note 1: assumes the local data occupies the first contiguous portion of the packed data
! - Note 2: does NOT copy the halo data; halo data values are out-of-sync after this call
subroutine from_fieldset(self, geom, vars, afieldset)

implicit none
class(fv3jedi_fields), intent(inout) :: self
type(fv3jedi_geom),    intent(in)    :: geom
type(oops_variables),  intent(in)    :: vars
type(atlas_fieldset),  intent(in)    :: afieldset

integer :: jvar, jl
real(kind=kind_real), pointer :: real_ptr(:,:)
type(atlas_field) :: afield
type(fv3jedi_field), pointer :: field
character(len=1024) :: errmsg

integer :: ngrid

do jvar = 1,vars%nvars()

  ! Get field
  call self%get_field(trim(vars%variable(jvar)), field)
  if (field%interface_specific) then
    call abor1_ftn("fv3jedi_fields_mod.from_fieldset_ad: interface-specific field requested")
  end if

  ! Get Atlas field
  afield = afieldset%field(field%long_name)

  ! Reshape the first portion of afield, the local data, into 2d fv3-jedi field
  call afield%data(real_ptr)
  do jl=1,field%npz
    field%array(geom%isc:geom%iec, geom%jsc:geom%jec, jl) = &
      reshape(real_ptr(jl, 1:geom%ngrid), (/geom%iec-geom%isc+1, geom%jec-geom%jsc+1/))
  enddo

  ! Release pointer
  call afield%final()

enddo

! Updated fields but not interface-specific fields, because these are not in atlas interface
if (self%ninterface_specific > 0) then
  self%interface_fields_are_out_of_date = .true.
end if

end subroutine from_fieldset

! --------------------------------------------------------------------------------------------------

subroutine update_fields(self, geom, new_vars)

implicit none

! Passed variables
class(fv3jedi_fields), intent(inout) :: self
type(fv3jedi_geom),    intent(in)    :: geom
type(oops_variables),  intent(in)    :: new_vars

type(fv3jedi_field), allocatable :: fields_tmp(:)
integer :: f, findex, new_ninterface_specific
type(field_metadata) :: fmd

! Allocate temporary array to hold fields
allocate(fields_tmp(new_vars%nvars()))
new_ninterface_specific = 0

! Loop over and move fields or allocate new fields
do f = 1, new_vars%nvars()

  fields_tmp(f)%isc = geom%isc
  fields_tmp(f)%iec = geom%iec
  fields_tmp(f)%jsc = geom%jsc
  fields_tmp(f)%jec = geom%jec

  fmd = geom%fmd%get_field_metadata(trim(new_vars%variable(f)))
  if (fmd%interface_specific) then
    new_ninterface_specific = new_ninterface_specific + 1
  end if

  if (self%has_field(trim(fmd%short_name), findex)) then

    ! If already allocated then move to temporary
    call move_alloc(self%fields(findex)%array, fields_tmp(f)%array)
    self%fields(findex)%lalloc = .false.
    fields_tmp(f)%lalloc = .true.

  endif

  ! Create field in temporary (allocate will be skipped if moved)
  call create_field(fields_tmp(f), fmd, geom%f_comm)

enddo

! Move the temporary array back to self
call self%delete()
call move_alloc(fields_tmp, self%fields)

! Update number of fields
self%nf = size(self%fields)
self%ninterface_specific = new_ninterface_specific

end subroutine update_fields

! --------------------------------------------------------------------------------------------------

logical function has_field_(self, field_name, field_index)

class(fv3jedi_fields), intent(in)  :: self
character(len=*),      intent(in)  :: field_name
integer, optional,     intent(out) :: field_index

has_field_ = hasfield(self%fields, field_name, field_index)

end function has_field_

! --------------------------------------------------------------------------------------------------

subroutine get_field_return_type_pointer(self, field_name, field)

class(fv3jedi_fields), target, intent(in)    :: self
character(len=*),              intent(in)    :: field_name
type(fv3jedi_field), pointer,  intent(inout) :: field

integer :: field_index

if (self%ninterface_specific > 0 .and. self%interface_fields_are_out_of_date) then
  if (self%has_field(field_name, field_index)) then  ! we really just want the index
    if (self%fields(field_index)%interface_specific) then
      call abor1_ftn("fv3jedi_fields_mod.get_field: interface-specific field requested but&
                     & interface-specific fields are out of date. Update before calling get_field")
    end if
  end if
end if

call get_field(self%fields, field_name, field)

! In principle, should set interface_fields_are_out_of_date here because the pointer can be used to
! modify the data. But this would be a major code change... so ignore this possibility for now...

endsubroutine get_field_return_type_pointer

! --------------------------------------------------------------------------------------------------

subroutine get_field_return_array_pointer(self, field_name, field)

class(fv3jedi_fields), target, intent(in)    :: self
character(len=*),              intent(in)    :: field_name
real(kind=kind_real), pointer, intent(inout) :: field(:,:,:)

integer :: field_index

if (self%ninterface_specific > 0 .and. self%interface_fields_are_out_of_date) then
  if (self%has_field(field_name, field_index)) then  ! we really just want the index
    if (self%fields(field_index)%interface_specific) then
      call abor1_ftn("fv3jedi_fields_mod.get_field: interface-specific field requested but&
                     & interface-specific fields are out of date. Update before calling get_field")
    end if
  end if
end if

call get_field(self%fields, field_name, field)

! In principle, should set interface_fields_are_out_of_date here because the pointer can be used to
! modify the data. But this would be a major code change... so ignore this possibility for now...

endsubroutine get_field_return_array_pointer

! --------------------------------------------------------------------------------------------------

subroutine get_field_return_array_allocatable(self, field_name, field)

class(fv3jedi_fields), target,     intent(in)    :: self
character(len=*),                  intent(in)    :: field_name
real(kind=kind_real), allocatable, intent(inout) :: field(:,:,:)

integer :: field_index

if (self%ninterface_specific > 0 .and. self%interface_fields_are_out_of_date) then
  if (self%has_field(field_name, field_index)) then  ! we really just want the index
    if (self%fields(field_index)%interface_specific) then
      call abor1_ftn("fv3jedi_fields_mod.get_field: interface-specific field requested but&
                     & interface-specific fields are out of date. Update before calling get_field")
    end if
  end if
end if

call get_field(self%fields, field_name, field)

endsubroutine get_field_return_array_allocatable

! --------------------------------------------------------------------------------------------------

subroutine put_field_(self, field_name, field)

class(fv3jedi_fields), target,     intent(inout) :: self
character(len=*),                  intent(in)    :: field_name
real(kind=kind_real), allocatable, intent(in)    :: field(:,:,:)

integer :: field_index

call put_field(self%fields, field_name, field)

! Set out-of-date if field_name is interface-specific
if (self%ninterface_specific > 0 .and. .not.  self%interface_fields_are_out_of_date) then
  if (self%has_field(field_name, field_index)) then  ! we really just want the index
    if (self%fields(field_index)%interface_specific) then
      self%interface_fields_are_out_of_date = .true.
    end if
  end if
end if

endsubroutine put_field_

! --------------------------------------------------------------------------------------------------

subroutine synchronize_interface_fields(self, geom)

class(fv3jedi_fields), target, intent(inout) :: self
class(fv3jedi_geom), intent(in) :: geom

type(fv3jedi_field), pointer :: ua
type(fv3jedi_field), pointer :: va
type(fv3jedi_field), pointer :: ud
type(fv3jedi_field), pointer :: vd

if (self%ninterface_specific > 0) then
  if (self%interface_fields_are_out_of_date) then

    ! Sanity-check we're not asking for an unsupported synchronization:
    ! For now, we only implement updating interface-specific ud,vd from ua,va
    if (self%ninterface_specific == 2) then
      ! check 2 fields are ud,vd
      if (.not. (self%has_field('ud') .and. self%has_field('vd'))) then
        call abor1_ftn("fv3jedi_fields_mod.synchronize_interface_fields: not yet generalized for&
                       & interface-specific fields beyond ud,vd")
      end if
      if (.not. (self%has_field('ua') .and. self%has_field('va'))) then
        call abor1_ftn("fv3jedi_fields_mod.synchronize_interface_fields: ua,va are required to&
                       & synchronize ud,vd from, but are missing")
      end if
    else
      call abor1_ftn("fv3jedi_fields_mod.synchronize_interface_fields: not yet generalized for&
                     & interface-specific fields beyond ud,vd")
    end if

    ! Update ud,vd from ua,va
    call get_field(self%fields, 'ud', ud)
    call get_field(self%fields, 'vd', vd)
    call get_field(self%fields, 'ua', ua)
    call get_field(self%fields, 'va', va)
    call a_to_d(geom, ua%array, va%array, ud%array, vd%array)

    self%interface_fields_are_out_of_date = .false.
  end if
end if

endsubroutine synchronize_interface_fields

! --------------------------------------------------------------------------------------------------

end module fv3jedi_fields_mod
