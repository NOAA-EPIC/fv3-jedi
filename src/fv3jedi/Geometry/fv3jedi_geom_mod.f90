! (C) Copyright 2017-2018 UCAR
!
! This software is licensed under the terms of the Apache Licence Version 2.0
! which can be obtained at http://www.apache.org/licenses/LICENSE-2.0.

!> Fortran module handling geometry for the FV3 model

module fv3jedi_geom_mod

!General JEDI uses
use fv3jedi_kinds_mod
use iso_c_binding
use fckit_mpi_module, only: fckit_mpi_comm
use netcdf
use mpi
use string_f_c_mod

use fckit_configuration_module, only: fckit_configuration

!FMS/MPP uses
use fckit_mpi_module,   only: fckit_mpi_comm
use mpp_domains_mod,    only: domain2D, mpp_deallocate_domain
use mpp_domains_mod,    only: mpp_define_layout, mpp_define_mosaic, mpp_define_io_domain
use mpp_mod,            only: mpp_pe, mpp_npes, mpp_error, FATAL, NOTE

use fv3jedi_netcdf_utils_mod, only: nccheck

!Uses for generating geometry using FV3 routines
use fv_arrays_nlm_mod,  only: fv_atmos_type, deallocate_fv_atmos_type
use fv_control_nlm_mod, only: fv_init, pelist_all

implicit none
private

public :: fv3jedi_geom
public :: create, clone, delete, info

! ------------------------------------------------------------------------------

!> Fortran derived type to hold geometry data for the FV3JEDI model
type :: fv3jedi_geom
  integer :: isd, ied, jsd, jed                                                     !data domain
  integer :: isc, iec, jsc, jec                                                     !compute domain
  integer :: npx,npy,npz                                                            !x/y/z-dir grid edge points per tile
  integer :: layout(2), io_layout(2)                                                !Processor layouts
  integer :: ntile, ntiles                                                          !Tile number and total
  real(kind=kind_real) :: ptop                                                      !Pressure at top of domain
  type(domain2D) :: domain_fix                                                      !MPP domain
  type(domain2D), pointer :: domain                                                 !MPP domain
  real(kind=kind_real), allocatable, dimension(:)       :: ak, bk                   !Model level coefficients
  real(kind=kind_real), allocatable, dimension(:,:)     :: grid_lon, grid_lat       !Lat/lon centers
  real(kind=kind_real), allocatable, dimension(:,:)     :: egrid_lon, egrid_lat     !Lat/lon edges
  real(kind=kind_real), allocatable, dimension(:,:)     :: area                     !Grid area
  real(kind=kind_real), allocatable, dimension(:,:)     :: dx, dy                   !dx/dy at edges
  real(kind=kind_real), allocatable, dimension(:,:)     :: dxc, dyc                 !dx/dy c grid
  real(kind=kind_real), allocatable, dimension(:,:,:)   :: grid, vlon, vlat
  real(kind=kind_real), allocatable, dimension(:)       :: edge_vect_n, edge_vect_e
  real(kind=kind_real), allocatable, dimension(:)       :: edge_vect_s, edge_vect_w
  real(kind=kind_real), allocatable, dimension(:,:,:,:) :: es, ew
  real(kind=kind_real), allocatable, dimension(:,:)     :: a11, a12, a21, a22
  type(fckit_mpi_comm) :: f_comm
  ! For D to (A to) C grid
  real(kind=kind_real), allocatable, dimension(:,:)     :: rarea
  real(kind=kind_real), allocatable, dimension(:,:,:)   :: sin_sg
  real(kind=kind_real), allocatable, dimension(:,:)     :: cosa_u
  real(kind=kind_real), allocatable, dimension(:,:)     :: cosa_v
  real(kind=kind_real), allocatable, dimension(:,:)     :: cosa_s
  real(kind=kind_real), allocatable, dimension(:,:)     :: rsin_u
  real(kind=kind_real), allocatable, dimension(:,:)     :: rsin_v
  real(kind=kind_real), allocatable, dimension(:,:)     :: rsin2
  real(kind=kind_real), allocatable, dimension(:,:)     :: dxa, dya
  logical :: ne_corner, se_corner, sw_corner, nw_corner
  logical :: nested = .false.
  integer :: grid_type = 0
  logical :: dord4 = .true.

end type fv3jedi_geom

! ------------------------------------------------------------------------------

contains

! ------------------------------------------------------------------------------

subroutine create(self, c_conf, f_comm)

implicit none

!Arguments
type(fv3jedi_geom), target,  intent(inout) :: self
type(c_ptr),                 intent(in)    :: c_conf
type(fckit_mpi_comm),        intent(in)    :: f_comm

!Locals
character(len=256)                    :: pathfile_akbk
type(fv_atmos_type), allocatable      :: FV_Atm(:)
logical, allocatable                  :: grids_on_this_pe(:)
integer                               :: p_split = 1
integer                               :: ncstat, ncid, akvarid, bkvarid, i, readdim, dcount
integer, dimension(nf90_max_var_dims) :: dimIDs, dimLens

type(fckit_configuration) :: f_conf
character(len=:), allocatable :: str
logical :: do_write_geom = .false.

! Add the communicator to the geometry
! ------------------------------------
self%f_comm = f_comm

! Fortran configuration
! ---------------------
f_conf = fckit_configuration(c_conf)


! Set path/filename for ak and bk
! -------------------------------
call f_conf%get_or_die("pathfile_akbk",str)
pathfile_akbk = str
deallocate(str)

!Intialize using the model setup routine
! --------------------------------------
call fv_init(FV_Atm, 300.0_kind_real, grids_on_this_pe, p_split)
deallocate(pelist_all)

self%isd = FV_Atm(1)%bd%isd
self%ied = FV_Atm(1)%bd%ied
self%jsd = FV_Atm(1)%bd%jsd
self%jed = FV_Atm(1)%bd%jed
self%isc = FV_Atm(1)%bd%isc
self%iec = FV_Atm(1)%bd%iec
self%jsc = FV_Atm(1)%bd%jsc
self%jec = FV_Atm(1)%bd%jec

self%ntile  = FV_Atm(1)%tile
self%ntiles = 6

self%npx = FV_Atm(1)%npx
self%npy = FV_Atm(1)%npy
self%npz = FV_Atm(1)%npz

self%layout(1) = FV_Atm(1)%layout(1)
self%layout(2) = FV_Atm(1)%layout(2)
self%io_layout(1) = FV_Atm(1)%io_layout(1)
self%io_layout(2) = FV_Atm(1)%io_layout(2)

!Allocatable arrays
allocate(self%ak(self%npz+1) )
allocate(self%bk(self%npz+1) )

allocate(self%grid_lon   (self%isd  :self%ied,  self%jsd  :self%jed  ))
allocate(self%grid_lat   (self%isd  :self%ied,  self%jsd  :self%jed  ))
allocate(self%egrid_lon  (self%isd  :self%ied+1,self%jsd  :self%jed+1))
allocate(self%egrid_lat  (self%isd  :self%ied+1,self%jsd  :self%jed+1))
allocate(self%area       (self%isd  :self%ied,  self%jsd  :self%jed  ))
allocate(self%dx         (self%isd  :self%ied  ,self%jsd  :self%jed+1))
allocate(self%dy         (self%isd  :self%ied+1,self%jsd  :self%jed  ))
allocate(self%dxc        (self%isd  :self%ied+1,self%jsd  :self%jed  ))
allocate(self%dyc        (self%isd  :self%ied  ,self%jsd  :self%jed+1))

allocate(self%grid       (self%isd  :self%ied+1,self%jsd  :self%jed+1,2))
allocate(self%vlon       (self%isc-2:self%iec+2,self%jsc-2:self%jec+2,3))
allocate(self%vlat       (self%isc-2:self%iec+2,self%jsc-2:self%jec+2,3))

allocate(self%edge_vect_n(self%isd:self%ied))
allocate(self%edge_vect_e(self%jsd:self%jed))
allocate(self%edge_vect_s(self%isd:self%ied))
allocate(self%edge_vect_w(self%jsd:self%jed))

allocate(self%es(3,self%isd:self%ied  ,self%jsd:self%jed+1,2))
allocate(self%ew(3,self%isd:self%ied+1,self%jsd:self%jed,  2))

allocate(self%a11(self%isc-1:self%iec+1,self%jsc-1:self%jec+1) )
allocate(self%a12(self%isc-1:self%iec+1,self%jsc-1:self%jec+1) )
allocate(self%a21(self%isc-1:self%iec+1,self%jsc-1:self%jec+1) )
allocate(self%a22(self%isc-1:self%iec+1,self%jsc-1:self%jec+1) )

allocate(self%rarea (self%isd:self%ied  ,self%jsd:self%jed  ))
allocate(self%sin_sg(self%isd:self%ied  ,self%jsd:self%jed  ,9))
allocate(self%cosa_u(self%isd:self%ied+1,self%jsd:self%jed  ))
allocate(self%cosa_v(self%isd:self%ied  ,self%jsd:self%jed+1))
allocate(self%cosa_s(self%isd:self%ied  ,self%jsd:self%jed  ))
allocate(self%rsin_u(self%isd:self%ied+1,self%jsd:self%jed  ))
allocate(self%rsin_v(self%isd:self%ied  ,self%jsd:self%jed+1))
allocate(self%rsin2 (self%isd:self%ied  ,self%jsd:self%jed  ))
allocate(self%dxa   (self%isd:self%ied  ,self%jsd:self%jed  ))
allocate(self%dya   (self%isd:self%ied  ,self%jsd:self%jed  ))

! ak and bk hybrid coordinate coefficients
! ----------------------------------------

!Open file
call nccheck ( nf90_open(pathfile_akbk, nf90_nowrite, ncid), "fv3jedi_geom, nf90_open "//pathfile_akbk )

!Search for ak in the file
ncstat = nf90_inq_varid(ncid, "AK", akvarid)
if(ncstat /= nf90_noerr) &
ncstat = nf90_inq_varid(ncid, "ak", akvarid)
if(ncstat /= nf90_noerr) &
ncstat = nf90_inq_varid(ncid, "Ak", akvarid)
if(ncstat /= nf90_noerr) &
call abor1_ftn("Failed to find ak in file "//pathfile_akbk//", tried AK, ak, Ak")

!Search for bk in the file
ncstat = nf90_inq_varid(ncid, "BK", bkvarid)
if(ncstat /= nf90_noerr) &
ncstat = nf90_inq_varid(ncid, "bk", bkvarid)
if(ncstat /= nf90_noerr) &
ncstat = nf90_inq_varid(ncid, "Bk", bkvarid)
if(ncstat /= nf90_noerr) &
call abor1_ftn("Failed to find bk in file "//pathfile_akbk//", tried BK, bk, Bk")

dimids = 0
call nccheck ( nf90_inquire_variable(ncid, akvarid, dimids = dimids), "fv3jedi_geom, nf90_inquire_variable ak" )

readdim = -1
dcount = 0
do i = 1,nf90_max_var_dims
  if (dimIDs(i) > 0) then
     call nccheck( nf90_inquire_dimension(ncid, dimIDs(i), len = dimlens(i)), "fv3jedi_geom, nf90_inquire_dimension" )
     if (dimlens(i) == self%npz+1) then
        readdim = i
     endif
     dcount = dcount + 1
  endif
enddo

if (readdim == -1) call abor1_ftn("fv3-jedi geometry: ak/bk in file does not match dimension of npz from input.nml")

!Read ak and bk from the file
call nccheck( nf90_get_var(ncid, akvarid, self%ak), "fv3jedi_geom, nf90_get_var ak" )
call nccheck( nf90_get_var(ncid, bkvarid, self%bk), "fv3jedi_geom, nf90_get_var bk" )


! Arrays from the FV_Atm Structure
! --------------------------------

self%grid_lon  = real(FV_Atm(1)%gridstruct%agrid_64(:,:,1),kind_real)
self%grid_lat  = real(FV_Atm(1)%gridstruct%agrid_64(:,:,2),kind_real)
self%egrid_lon = real(FV_Atm(1)%gridstruct%grid_64(:,:,1),kind_real)
self%egrid_lat = real(FV_Atm(1)%gridstruct%grid_64(:,:,2),kind_real)
self%area      = real(FV_Atm(1)%gridstruct%area_64,kind_real)
self%dx        = real(Fv_Atm(1)%gridstruct%dx ,kind_real)
self%dy        = real(Fv_Atm(1)%gridstruct%dy ,kind_real)
self%dxc       = real(Fv_Atm(1)%gridstruct%dxc,kind_real)
self%dyc       = real(Fv_Atm(1)%gridstruct%dyc,kind_real)

self%grid      = real(FV_Atm(1)%gridstruct%grid,kind_real)
self%vlon      = real(Fv_Atm(1)%gridstruct%vlon,kind_real)
self%vlat      = real(Fv_Atm(1)%gridstruct%vlat,kind_real)

self%edge_vect_n = real(Fv_Atm(1)%gridstruct%edge_vect_n,kind_real)
self%edge_vect_e = real(Fv_Atm(1)%gridstruct%edge_vect_e,kind_real)
self%edge_vect_s = real(Fv_Atm(1)%gridstruct%edge_vect_s,kind_real)
self%edge_vect_w = real(Fv_Atm(1)%gridstruct%edge_vect_w,kind_real)

self%es = real(Fv_Atm(1)%gridstruct%es,kind_real)
self%ew = real(Fv_Atm(1)%gridstruct%ew,kind_real)

self%a11 = real(Fv_Atm(1)%gridstruct%a11,kind_real)
self%a12 = real(Fv_Atm(1)%gridstruct%a12,kind_real)
self%a21 = real(Fv_Atm(1)%gridstruct%a21,kind_real)
self%a22 = real(Fv_Atm(1)%gridstruct%a22,kind_real)

self%rarea     = real(Fv_Atm(1)%gridstruct%rarea ,kind_real)
self%sin_sg    = real(Fv_Atm(1)%gridstruct%sin_sg,kind_real)
self%cosa_u    = real(Fv_Atm(1)%gridstruct%cosa_u,kind_real)
self%cosa_v    = real(Fv_Atm(1)%gridstruct%cosa_v,kind_real)
self%cosa_s    = real(Fv_Atm(1)%gridstruct%cosa_s,kind_real)
self%rsin_u    = real(Fv_Atm(1)%gridstruct%rsin_u,kind_real)
self%rsin_v    = real(Fv_Atm(1)%gridstruct%rsin_v,kind_real)
self%rsin2     = real(Fv_Atm(1)%gridstruct%rsin2 ,kind_real)
self%dxa       = real(Fv_Atm(1)%gridstruct%dxa   ,kind_real)
self%dya       = real(Fv_Atm(1)%gridstruct%dya   ,kind_real)
self%ne_corner = Fv_Atm(1)%gridstruct%ne_corner
self%se_corner = Fv_Atm(1)%gridstruct%se_corner
self%sw_corner = Fv_Atm(1)%gridstruct%sw_corner
self%nw_corner = Fv_Atm(1)%gridstruct%nw_corner

!Set Ptop
self%ptop = self%ak(1)

!Done with the FV_Atm stucture here
call deallocate_fv_atmos_type(FV_Atm(1))
deallocate(FV_Atm)
deallocate(grids_on_this_pe)

!Resetup domain to avoid risk of copied pointers
call setup_domain( self%domain_fix, self%npx-1, self%npx-1, &
                   self%ntiles, self%layout, self%io_layout, 3)

self%domain => self%domain_fix

! Optionally write the geometry to file
! -------------------------------------
if (f_conf%has("do_write_geom")) then
  call f_conf%get_or_die("do_write_geom",do_write_geom)
endif

if (do_write_geom) then
  call write_geom(self)
endif

end subroutine create

! ------------------------------------------------------------------------------

subroutine clone(self, other)

implicit none

type(fv3jedi_geom), target, intent(in)    :: self
type(fv3jedi_geom),         intent(inout) :: other

allocate(other%ak(self%npz+1) )
allocate(other%bk(self%npz+1) )

allocate(other%grid_lon   (self%isd  :self%ied,  self%jsd  :self%jed  ))
allocate(other%grid_lat   (self%isd  :self%ied,  self%jsd  :self%jed  ))
allocate(other%egrid_lon  (self%isd  :self%ied+1,self%jsd  :self%jed+1))
allocate(other%egrid_lat  (self%isd  :self%ied+1,self%jsd  :self%jed+1))
allocate(other%area       (self%isd  :self%ied,  self%jsd  :self%jed  ))
allocate(other%dx         (self%isd  :self%ied  ,self%jsd  :self%jed+1))
allocate(other%dy         (self%isd  :self%ied+1,self%jsd  :self%jed  ))
allocate(other%dxc        (self%isd  :self%ied+1,self%jsd  :self%jed  ))
allocate(other%dyc        (self%isd  :self%ied  ,self%jsd  :self%jed+1))

allocate(other%grid       (self%isd  :self%ied+1,self%jsd  :self%jed+1,2))
allocate(other%vlon       (self%isc-2:self%iec+2,self%jsc-2:self%jec+2,3))
allocate(other%vlat       (self%isc-2:self%iec+2,self%jsc-2:self%jec+2,3))

allocate(other%edge_vect_n(self%isd:self%ied))
allocate(other%edge_vect_e(self%jsd:self%jed))
allocate(other%edge_vect_s(self%isd:self%ied))
allocate(other%edge_vect_w(self%jsd:self%jed))

allocate(other%es(3,self%isd:self%ied  ,self%jsd:self%jed+1,2))
allocate(other%ew(3,self%isd:self%ied+1,self%jsd:self%jed,  2))

allocate(other%a11(self%isc-1:self%iec+1,self%jsc-1:self%jec+1) )
allocate(other%a12(self%isc-1:self%iec+1,self%jsc-1:self%jec+1) )
allocate(other%a21(self%isc-1:self%iec+1,self%jsc-1:self%jec+1) )
allocate(other%a22(self%isc-1:self%iec+1,self%jsc-1:self%jec+1) )

allocate(other%rarea (self%isd:self%ied  ,self%jsd:self%jed  ))
allocate(other%sin_sg(self%isd:self%ied  ,self%jsd:self%jed  ,9))
allocate(other%cosa_u(self%isd:self%ied+1,self%jsd:self%jed  ))
allocate(other%cosa_v(self%isd:self%ied  ,self%jsd:self%jed+1))
allocate(other%cosa_s(self%isd:self%ied  ,self%jsd:self%jed  ))
allocate(other%rsin_u(self%isd:self%ied+1,self%jsd:self%jed  ))
allocate(other%rsin_v(self%isd:self%ied  ,self%jsd:self%jed+1))
allocate(other%rsin2 (self%isd:self%ied  ,self%jsd:self%jed  ))
allocate(other%dxa   (self%isd:self%ied  ,self%jsd:self%jed  ))
allocate(other%dya   (self%isd:self%ied  ,self%jsd:self%jed  ))

other%npx             = self%npx
other%npy             = self%npy
other%npz             = self%npz
other%layout          = self%layout
other%io_layout       = self%io_layout
other%isc             = self%isc
other%isd             = self%isd
other%iec             = self%iec
other%ied             = self%ied
other%jsc             = self%jsc
other%jsd             = self%jsd
other%jec             = self%jec
other%jed             = self%jed
other%ntile           = self%ntile
other%ntiles          = self%ntiles
other%ptop            = self%ptop
other%ak              = self%ak
other%bk              = self%bk
other%grid_lon        = self%grid_lon
other%grid_lat        = self%grid_lat
other%egrid_lon       = self%egrid_lon
other%egrid_lat       = self%egrid_lat
other%area            = self%area
other%dx              = self%dx
other%dy              = self%dy
other%dxc             = self%dxc
other%dyc             = self%dyc
other%grid            = self%grid
other%vlon            = self%vlon
other%vlat            = self%vlat
other%edge_vect_n     = self%edge_vect_n
other%edge_vect_e     = self%edge_vect_e
other%edge_vect_s     = self%edge_vect_s
other%edge_vect_w     = self%edge_vect_w
other%es              = self%es
other%ew              = self%ew
other%a11             = self%a11
other%a12             = self%a12
other%a21             = self%a21
other%a22             = self%a22
other%f_comm          = self%f_comm

other%rarea     = self%rarea
other%sin_sg    = self%sin_sg
other%cosa_u    = self%cosa_u
other%cosa_v    = self%cosa_v
other%cosa_s    = self%cosa_s
other%rsin_u    = self%rsin_u
other%rsin_v    = self%rsin_v
other%rsin2     = self%rsin2
other%dxa       = self%dxa
other%dya       = self%dya
other%ne_corner = self%ne_corner
other%se_corner = self%se_corner
other%sw_corner = self%sw_corner
other%nw_corner = self%nw_corner

other%domain => self%domain

end subroutine clone

! ------------------------------------------------------------------------------

subroutine delete(self)

implicit none

type(fv3jedi_geom), intent(inout) :: self

! Deallocate
deallocate(self%ak)
deallocate(self%bk)
deallocate(self%grid_lon)
deallocate(self%grid_lat)
deallocate(self%egrid_lon)
deallocate(self%egrid_lat)
deallocate(self%area)
deallocate(self%dx)
deallocate(self%dy)
deallocate(self%dxc)
deallocate(self%dyc)
deallocate(self%grid)
deallocate(self%vlon)
deallocate(self%vlat)
deallocate(self%edge_vect_n)
deallocate(self%edge_vect_e)
deallocate(self%edge_vect_s)
deallocate(self%edge_vect_w)
deallocate(self%es)
deallocate(self%ew)
deallocate(self%a11)
deallocate(self%a12)
deallocate(self%a21)
deallocate(self%a22)

deallocate(self%rarea)
deallocate(self%sin_sg)
deallocate(self%cosa_u)
deallocate(self%cosa_v)
deallocate(self%cosa_s)
deallocate(self%rsin_u)
deallocate(self%rsin_v)
deallocate(self%rsin2 )
deallocate(self%dxa   )
deallocate(self%dya   )

! Required memory leak, since copying this causes problems
!call mpp_deallocate_domain(self%domain_fix)

end subroutine delete

! ------------------------------------------------------------------------------

subroutine info(self)

implicit none

type(fv3jedi_geom), intent(in) :: self

end subroutine info

! ------------------------------------------------------------------------------

subroutine setup_domain(domain, nx, ny, ntiles, layout_in, io_layout, halo)

 implicit none

 type(domain2D),   intent(inout) :: domain
 integer,          intent(in)    :: nx, ny, ntiles
 integer,          intent(in)    :: layout_in(:), io_layout(:)
 integer,          intent(in)    :: halo

 integer                              :: pe, npes, npes_per_tile, tile
 integer                              :: num_contact
 integer                              :: n, layout(2)
 integer, allocatable, dimension(:,:) :: global_indices, layout2D
 integer, allocatable, dimension(:)   :: pe_start, pe_end
 integer, allocatable, dimension(:)   :: tile1, tile2
 integer, allocatable, dimension(:)   :: istart1, iend1, jstart1, jend1
 integer, allocatable, dimension(:)   :: istart2, iend2, jstart2, jend2
 integer, allocatable :: tile_id(:)
 logical :: is_symmetry

  pe = mpp_pe()
  npes = mpp_npes()

  if (mod(npes,ntiles) /= 0) then
     call mpp_error(NOTE, "setup_domain: npes can not be divided by ntiles")
     return
  endif
  npes_per_tile = npes/ntiles
  tile = pe/npes_per_tile + 1

  if (layout_in(1)*layout_in(2) == npes_per_tile) then
     layout = layout_in
  else
     call mpp_define_layout( (/1,nx,1,ny/), npes_per_tile, layout )
  endif

  if (io_layout(1) <1 .or. io_layout(2) <1) call mpp_error(FATAL, &
          "setup_domain: both elements of variable io_layout must be positive integer")
  if (mod(layout(1), io_layout(1)) /= 0 ) call mpp_error(FATAL, &
       "setup_domain: layout(1) must be divided by io_layout(1)")
  if (mod(layout(2), io_layout(2)) /= 0 ) call mpp_error(FATAL, &
       "setup_domain: layout(2) must be divided by io_layout(2)")

  allocate(global_indices(4,ntiles), layout2D(2,ntiles), pe_start(ntiles), pe_end(ntiles) )
  do n = 1, ntiles
     global_indices(:,n) = (/1,nx,1,ny/)
     layout2D(:,n)       = layout
     pe_start(n)         = (n-1)*npes_per_tile
     pe_end(n)           = n*npes_per_tile-1
  enddo

  ! this code copied from domain_decomp in fv_mp_mod.f90
  num_contact = 12
  allocate(tile1(num_contact), tile2(num_contact) )
  allocate(tile_id(ntiles))
  allocate(istart1(num_contact), iend1(num_contact), jstart1(num_contact), jend1(num_contact) )
  allocate(istart2(num_contact), iend2(num_contact), jstart2(num_contact), jend2(num_contact) )
  !--- Contact line 1, between tile 1 (EAST) and tile 2 (WEST)
  tile1(1) = 1; tile2(1) = 2
  istart1(1) = nx; iend1(1) = nx; jstart1(1) = 1;  jend1(1) = ny
  istart2(1) = 1;  iend2(1) = 1;  jstart2(1) = 1;  jend2(1) = ny
  !--- Contact line 2, between tile 1 (NORTH) and tile 3 (WEST)
  tile1(2) = 1; tile2(2) = 3
  istart1(2) = 1;  iend1(2) = nx; jstart1(2) = ny; jend1(2) = ny
  istart2(2) = 1;  iend2(2) = 1;  jstart2(2) = ny; jend2(2) = 1
  !--- Contact line 3, between tile 1 (WEST) and tile 5 (NORTH)
  tile1(3) = 1; tile2(3) = 5
  istart1(3) = 1;  iend1(3) = 1;  jstart1(3) = 1;  jend1(3) = ny
  istart2(3) = nx; iend2(3) = 1;  jstart2(3) = ny; jend2(3) = ny
  !--- Contact line 4, between tile 1 (SOUTH) and tile 6 (NORTH)
  tile1(4) = 1; tile2(4) = 6
  istart1(4) = 1;  iend1(4) = nx; jstart1(4) = 1;  jend1(4) = 1
  istart2(4) = 1;  iend2(4) = nx; jstart2(4) = ny; jend2(4) = ny
  !--- Contact line 5, between tile 2 (NORTH) and tile 3 (SOUTH)
  tile1(5) = 2; tile2(5) = 3
  istart1(5) = 1;  iend1(5) = nx; jstart1(5) = ny; jend1(5) = ny
  istart2(5) = 1;  iend2(5) = nx; jstart2(5) = 1;  jend2(5) = 1
  !--- Contact line 6, between tile 2 (EAST) and tile 4 (SOUTH)
  tile1(6) = 2; tile2(6) = 4
  istart1(6) = nx; iend1(6) = nx; jstart1(6) = 1;  jend1(6) = ny
  istart2(6) = nx; iend2(6) = 1;  jstart2(6) = 1;  jend2(6) = 1
  !--- Contact line 7, between tile 2 (SOUTH) and tile 6 (EAST)
  tile1(7) = 2; tile2(7) = 6
  istart1(7) = 1;  iend1(7) = nx; jstart1(7) = 1;  jend1(7) = 1
  istart2(7) = nx; iend2(7) = nx; jstart2(7) = ny; jend2(7) = 1
  !--- Contact line 8, between tile 3 (EAST) and tile 4 (WEST)
  tile1(8) = 3; tile2(8) = 4
  istart1(8) = nx; iend1(8) = nx; jstart1(8) = 1;  jend1(8) = ny
  istart2(8) = 1;  iend2(8) = 1;  jstart2(8) = 1;  jend2(8) = ny
  !--- Contact line 9, between tile 3 (NORTH) and tile 5 (WEST)
  tile1(9) = 3; tile2(9) = 5
  istart1(9) = 1;  iend1(9) = nx; jstart1(9) = ny; jend1(9) = ny
  istart2(9) = 1;  iend2(9) = 1;  jstart2(9) = ny; jend2(9) = 1
  !--- Contact line 10, between tile 4 (NORTH) and tile 5 (SOUTH)
  tile1(10) = 4; tile2(10) = 5
  istart1(10) = 1;  iend1(10) = nx; jstart1(10) = ny; jend1(10) = ny
  istart2(10) = 1;  iend2(10) = nx; jstart2(10) = 1;  jend2(10) = 1
  !--- Contact line 11, between tile 4 (EAST) and tile 6 (SOUTH)
  tile1(11) = 4; tile2(11) = 6
  istart1(11) = nx; iend1(11) = nx; jstart1(11) = 1;  jend1(11) = ny
  istart2(11) = nx; iend2(11) = 1;  jstart2(11) = 1;  jend2(11) = 1
  !--- Contact line 12, between tile 5 (EAST) and tile 6 (WEST)
  tile1(12) = 5; tile2(12) = 6
  istart1(12) = nx; iend1(12) = nx; jstart1(12) = 1;  jend1(12) = ny
  istart2(12) = 1;  iend2(12) = 1;  jstart2(12) = 1;  jend2(12) = ny
  is_symmetry = .true.
  do n = 1, ntiles
     tile_id(n) = n
  enddo

  call mpp_define_mosaic(global_indices, layout2D, domain, ntiles, num_contact, tile1, tile2, &
                         istart1, iend1, jstart1, jend1, istart2, iend2, jstart2, jend2,      &
                         pe_start, pe_end, whalo=halo, ehalo=halo, shalo=halo, nhalo=halo,    &
                         symmetry=is_symmetry, tile_id=tile_id, &
                         name='cubic_grid')

  if (io_layout(1) /= 1 .or. io_layout(2) /= 1) call mpp_define_io_domain(domain, io_layout)

  deallocate(pe_start, pe_end)
  deallocate(layout2D, global_indices)
  deallocate(tile1, tile2, tile_id)
  deallocate(istart1, iend1, jstart1, jend1)
  deallocate(istart2, iend2, jstart2, jend2)

end subroutine setup_domain

! ------------------------------------------------------------------------------

subroutine write_geom(self)

  implicit none
  type(fv3jedi_geom), intent(in) :: self

  type(fckit_mpi_comm) :: f_comm
  character(len=255) :: filename
  integer :: ncid, xf_dimid, yf_dimid, xv_dimid, yv_dimid, ti_dimid, pe_dimid
  integer :: mydims(3,3), ijdims(1), ijdimf(1), tmpij(1)
  integer :: varid(8)


  ! Pointer to fv3jedi geom communicator
  f_comm = self%f_comm

  write(filename,"(A9,I0.4,A4)") 'fv3grid_c', self%npx-1, '.nc4'

  ! Create and open the file for parallel write
  call nccheck( nf90_create( trim(filename), ior(NF90_NETCDF4, NF90_MPIIO), ncid, &
                             comm = f_comm%communicator(), info = MPI_INFO_NULL), "nf90_create" )

  !Dimensions
  call nccheck ( nf90_def_dim(ncid, 'fxdim', self%npx-1   , xf_dimid), "nf90_def_dim fxdim" )
  call nccheck ( nf90_def_dim(ncid, 'fydim', self%npy-1   , yf_dimid), "nf90_def_dim fydim" )
  call nccheck ( nf90_def_dim(ncid, 'vxdim', self%npx     , xv_dimid), "nf90_def_dim vxdim" )
  call nccheck ( nf90_def_dim(ncid, 'vydim', self%npy     , yv_dimid), "nf90_def_dim vydim" )
  call nccheck ( nf90_def_dim(ncid, 'ntile', 6            , ti_dimid), "nf90_def_dim ntile" )
  call nccheck ( nf90_def_dim(ncid, 'nproc', f_comm%size(), pe_dimid), "nf90_def_dim ntile" )

  !Define variables
  call nccheck( nf90_def_var(ncid, "flons", NF90_DOUBLE, (/ xf_dimid, yf_dimid, ti_dimid /), varid(1)), "nf90_def_var flons" )
  call nccheck( nf90_put_att(ncid, varid(1), "long_name", "longitude of faces") )
  call nccheck( nf90_put_att(ncid, varid(1), "units", "degrees_east") )

  call nccheck( nf90_def_var(ncid, "flats", NF90_DOUBLE, (/ xf_dimid, yf_dimid, ti_dimid /), varid(2)), "nf90_def_var flats" )
  call nccheck( nf90_put_att(ncid, varid(2), "long_name", "latitude of faces") )
  call nccheck( nf90_put_att(ncid, varid(2), "units", "degrees_north") )

  call nccheck( nf90_def_var(ncid, "vlons", NF90_DOUBLE, (/ xv_dimid, yv_dimid, ti_dimid /), varid(3)), "nf90_def_var vlons" )
  call nccheck( nf90_put_att(ncid, varid(3), "long_name", "longitude of vertices") )
  call nccheck( nf90_put_att(ncid, varid(3), "units", "degrees_east") )

  call nccheck( nf90_def_var(ncid, "vlats", NF90_DOUBLE, (/ xv_dimid, yv_dimid, ti_dimid /), varid(4)), "nf90_def_var vlats" )
  call nccheck( nf90_put_att(ncid, varid(4), "long_name", "latitude of vertices") )
  call nccheck( nf90_put_att(ncid, varid(4), "units", "degrees_north") )

  call nccheck( nf90_def_var(ncid, "isc", NF90_INT, (/ pe_dimid /), varid(5)), "nf90_def_var isc" )
  call nccheck( nf90_put_att(ncid, varid(5), "long_name", "starting index i direction") )
  call nccheck( nf90_put_att(ncid, varid(5), "units", "1") )

  call nccheck( nf90_def_var(ncid, "iec", NF90_INT, (/ pe_dimid /), varid(6)), "nf90_def_var iec" )
  call nccheck( nf90_put_att(ncid, varid(6), "long_name", "ending index i direction") )
  call nccheck( nf90_put_att(ncid, varid(6), "units", "1") )

  call nccheck( nf90_def_var(ncid, "jsc", NF90_INT, (/ pe_dimid /), varid(7)), "nf90_def_var jsc" )
  call nccheck( nf90_put_att(ncid, varid(7), "long_name", "starting index j direction") )
  call nccheck( nf90_put_att(ncid, varid(7), "units", "1") )

  call nccheck( nf90_def_var(ncid, "jec", NF90_INT, (/ pe_dimid /), varid(8)), "nf90_def_var jec" )
  call nccheck( nf90_put_att(ncid, varid(8), "long_name", "ending index j direction") )
  call nccheck( nf90_put_att(ncid, varid(8), "units", "1") )

  ! End define mode
  call nccheck( nf90_enddef(ncid), "nf90_enddef" )

  ! Write variables
  mydims(1,1) = 1;          mydims(2,1) = self%npx-1
  mydims(1,2) = 1;          mydims(2,2) = self%npy-1
  mydims(1,3) = self%ntile; mydims(2,3) = 1

  call nccheck( nf90_put_var( ncid, varid(1), self%grid_lon(self%isc:self%iec,self%jsc:self%jec), &
                              start = mydims(1,:), count = mydims(2,:) ), "nf90_put_var flons" )

  call nccheck( nf90_put_var( ncid, varid(2), self%grid_lat(self%isc:self%iec,self%jsc:self%jec), &
                              start = mydims(1,:), count = mydims(2,:) ), "nf90_put_var flats" )

  mydims(1,1) = 1;          mydims(2,1) = self%npx
  mydims(1,2) = 1;          mydims(2,2) = self%npy
  mydims(1,3) = self%ntile; mydims(2,3) = 1

  call nccheck( nf90_put_var( ncid, varid(3), self%egrid_lon(self%isc:self%iec+1,self%jsc:self%jec+1), &
                              start = mydims(1,:), count = mydims(2,:) ), "nf90_put_var vlons" )

  call nccheck( nf90_put_var( ncid, varid(4), self%egrid_lat(self%isc:self%iec+1,self%jsc:self%jec+1), &
                              start = mydims(1,:), count = mydims(2,:) ), "nf90_put_var vlats" )

  ijdims(1) = f_comm%rank()+1
  ijdimf(1) = 1

  tmpij = self%isc
  call nccheck( nf90_put_var( ncid, varid(5), tmpij, start = ijdims, count = ijdimf ), "nf90_put_var isc" )

  tmpij = self%iec
  call nccheck( nf90_put_var( ncid, varid(6), tmpij, start = ijdims, count = ijdimf ), "nf90_put_var iec" )

  tmpij = self%jsc
  call nccheck( nf90_put_var( ncid, varid(7), tmpij, start = ijdims, count = ijdimf ), "nf90_put_var jsc" )

  tmpij = self%jec
  call nccheck( nf90_put_var( ncid, varid(8), tmpij, start = ijdims, count = ijdimf ), "nf90_put_var jec" )

  ! Close the file
  call nccheck ( nf90_close(ncid), "nf90_close" )

end subroutine write_geom

! ------------------------------------------------------------------------------

end module fv3jedi_geom_mod
