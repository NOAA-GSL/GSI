module aniso_ens_util
!$$$  subprogram documentation block
!                .      .    .                                       .
! module:  aniso_ens_util
! prgmmr: sato             org: np22                date: 2008-10-03
!
! abstract: some utilities for ensemble based anisotropy,
!           extracted from anisofilter.
!
! program history log:
!   2008-10-03  sato
!
! subroutines included:
!
!   ens_uv_to_psichi   - convert uv field to psichi for regional mode
!   set_grdparm212     - projection parameter settings for 212 grid
!   set_grdparm221     - projection parameter settings for 221 grid
!   ens_intpcoeffs_reg - prepare interpolation coefficient
!   fillanlgrd         - fill analysis grid with ensemble input
!   ens_mirror         - mirroring for the out of the input domain
!   pges_minmax
!   check_32primes
!   ens_fill
!   ens_unfill
!
!---
! attributes:
!   language: f90
!   machine:  ibm RS/6000 SP
!
! Uses:

contains

!=======================================================================
subroutine ens_uv_to_psichi(u,v,truewind,mype)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:  ens_uv_to_psichi
! prgmmr: pondeca          org: np22                date: 2007-03-08
!
! abstract: given earth u and v on analysis grid, rotate wind to get
!           grid-relative u and v components, compute divergence and
!           vorticity and call subroutine that converts into
!           streamfunction and velocity potential.
!
! program history log:
!   2008-08-21  pondeca
!
!   input argument list:
!    mype           - mpi task id
!    u(nlat,nlon)              - earth relative u-field on analysis grid
!    v(nlat,nlon)              - earth relative v-field on analysis grid
!   output argument list:
!    u(nlat,nlon)              - streamfunction on analysis grid
!    v(nlat,nlon)              - velocity potential on analysis grid
!
! attributes:
!   language: f90
!   machine:  ibm RS/6000 SP
!
! Uses:
  use kinds, only: i_kind, r_kind, r_single
  use constants, only: one
  use gridmod, only: nlon,nlat,region_lon,region_lat,region_dx,region_dy, &
                     rotate_wind_ll2xy
  use wind_fft, only: divvort_to_psichi

  implicit none

! Declare passed variables
  real(r_single),intent(inout):: u(nlat,nlon),v(nlat,nlon)
  integer(i_kind),intent(in):: mype
  logical,intent(in):: truewind


! Declare local variables
  integer(i_kind) i,j,im,ip,jm,jp

  real(r_kind) rlon,rlat,dlon,dlat
  real(r_kind) ue,ve,ug,vg
  real(r_kind) dxi,dyi
  real(r_single),allocatable,dimension(:,:)::div,vort,psi,chi
  real(r_single),allocatable,dimension(:,:)::divb,vortb
  real(r_single),allocatable,dimension(:,:,:)::tqg
  real(r_single),allocatable,dimension(:,:)::dxy,dxyb,tdxyb

  integer(i_kind) ijext,n0,n1,nxb,nyb
  integer(i_kind) nxs,nxe,nys,nye
  integer(i_kind) mmaxb,nmaxb

  logical lprime, no_wgt

!==========================================================================
!==>rotation to get analysis grid-relative wind
!==========================================================================
! print*,'in ens_uv_to_psichi: region_lon,min,max=', &
!                              minval(region_lon),maxval(region_lon)
! print*,'in ens_uv_to_psichi: region_lat,min,max=', &
!                              minval(region_lat),maxval(region_lat)
  do i=1,nlat
   do j=1,nlon
     rlon=region_lon(i,j)
     rlat=region_lat(i,j)
     dlon=float(j)*one
     dlat=float(i)*one
     ue=u(i,j)
     ve=v(i,j)
     call rotate_wind_ll2xy(ue,ve,ug,vg,rlon,rlat,dlon,dlat)
     u(i,j)=ug
     v(i,j)=vg
  enddo
 enddo
 if (truewind) return
!==========================================================================
!==>divergence and vorticity computation
!==========================================================================
  allocate(div(nlat,nlon))
  allocate(vort(nlat,nlon))
  do i=1,nlat
    im=max(1,i-1)
    ip=min(nlat,i+1)
    do j=1,nlon
      jm=max(1,j-1)
      jp=min(nlon,j+1)
      dxi=one/((jp-jm)*region_dx(i,j))
      dyi=one/((ip-im)*region_dy(i,j))
      div(i,j)= (u(i,jp)-u(i,jm))*dxi + (v(ip,j)-v(im,j))*dyi
      vort(i,j)=(v(i,jp)-v(i,jm))*dxi - (u(ip,j)-u(im,j))*dyi
  enddo
 enddo

 allocate(dxy(nlat,nlon))
 dxy=(region_dx+region_dy)/2._r_kind

!==========================================================================
!==>expand domain in preparation for fft use
!==========================================================================
      n0=max(nlat,nlon)
      ijext=4
100   continue
      n1=n0+2*ijext
      call check_32primes(n1,lprime)
      if (.not.lprime) then
         ijext=ijext+1
         goto 100
      endif

      nxs=ijext+1
      nxe=ijext+nlon
      nys=ijext+1
      nye=ijext+nlat

      nxb=n1
      nyb=n1

      allocate(divb(1:nyb,1:nxb))
      allocate(vortb(1:nyb,1:nxb))
      allocate(dxyb(1:nyb,1:nxb))

      no_wgt=.false.
      call ens_fill(divb ,nxb,nyb,div ,nlat,nlon,ijext,no_wgt)
      call ens_fill(vortb,nxb,nyb,vort,nlat,nlon,ijext,no_wgt)
      no_wgt=.true.
      call ens_fill(dxyb ,nxb,nyb,dxy ,nlat,nlon,ijext,no_wgt)

      allocate(tqg(1:nxb,1:nyb,2))  !note reverse order of indices
      allocate(tdxyb(1:nxb,1:nyb)) !note reverse order of indices

      do i=1,nyb
      do j=1,nxb
         tqg(j,i,1)=divb(i,j)
         tqg(j,i,2)=vortb(i,j)
         tdxyb(j,i)=dxyb(i,j)
      enddo
      enddo

      mmaxb=nxb/3-1
      nmaxb=nyb/3-1

      call divvort_to_psichi(nxb,nyb,mmaxb,nmaxb,tdxyb,tqg)

      do i=1,nyb
      do j=1,nxb
         divb(i,j)=tqg(j,i,1)  !vel potential
         vortb(i,j)=tqg(j,i,2)  !streamfunction
      enddo
      enddo

      call ens_unfill(vortb,nxb,nyb,u,nlat,nlon)
      call ens_unfill(divb ,nxb,nyb,v,nlat,nlon)

      !in future may add call here to get unbalanced part of chi

      deallocate(div)
      deallocate(vort)
      deallocate(divb)
      deallocate(vortb)
      deallocate(tqg)
      deallocate(dxy)
      deallocate(dxyb)
      deallocate(tdxyb)
end subroutine ens_uv_to_psichi
!  --------------------------------------------------------------
!=======================================================================
!=======================================================================
subroutine set_grdparm212(iy,jx,jxp,alat1,elon1,ds,elonv,alatan)
  use kinds, only: i_kind, r_kind
  implicit none
  integer(i_kind),intent(out):: iy,jx,jxp
  real(r_kind),intent(out):: alat1,elon1,ds,elonv,alatan
  iy=129
  jx=185
  jxp=jx
  ds=40635.25_r_kind
  alat1=12.190_r_kind
  elon1=226.541_r_kind
  elonv=265.000_r_kind
  alatan=25.000_r_kind
end subroutine set_grdparm212
!=======================================================================
!=======================================================================
subroutine set_grdparm221(iy,jx,jxp,alat1,elon1,ds,elonv,alatan)
  use kinds, only: i_kind, r_kind
  implicit none
  integer(i_kind),intent(out):: iy,jx,jxp
  real(r_kind),intent(out):: alat1,elon1,ds,elonv,alatan
  iy=277
  jx=349
  jxp=jx
  ds=32463.41_r_kind
  alat1=1.000_r_kind
  elon1=214.500_r_kind
  elonv=253.000_r_kind
  alatan=50.000_r_kind
end subroutine set_grdparm221
!=======================================================================
!=======================================================================
subroutine ens_intpcoeffs_reg(ngrds,igbox,iref,jref,igbox0f,ensmask,enscoeff,gblend,mype)
!
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    ens_intpcoeffs_reg
!   prgmmr: pondeca          org: np22                date: 2006-07-06
!
! abstract: compute coefficients of horizontal bilinear
!           interpolation of ensemble field to analysis grid.
!           also load mask fields with a value of 1 if grid point
!           of analysis grid is within bounds of the ensemble
!           grid and -1 otherwise. supported ensemble grids are
!           awips 212, 221, and 3 (1dg x 1dg global grid)
!
! (pt#2) i+1,j |            | i+1,j+1  (pt#4)
!            --+------------+---
!              |            | dyg1
!              |     *      + -
!              |    X,Y     | dyg
!              |            |
!            --+-----+------+---
! (pt#1)    i,j|<dxg>|<dxg1>| i,j+1     (pt#3)
!
!     note: fields are assumed to be
!           dimensioned as field(nlatdirection,nlondirection)
!
! program history log:
!   2007-02-24  pondeca
!
!   input argument list:
!     mype     - mpi task id
!
!   output argument list:
!     enscoeff(:,:,:,1) - interpolation coeffs for grid 212
!     enscoeff(:,:,:,2) - interpolation coeffs for grid 221
!     enscoeff(:,:,:,3) - interpolation coeffs for global grid
!     igbox(4,3) - first indice is associated with the corner i and j
!                  values of the largest rectangular portion of the
!                  analysis grid that falls completely inside the
!                  ensemble grid. second index is for grids 212, 221 and
!                  global grid.
!     igbox0f(4,3) - same as igbox but values valid for filter grid
!     gblend(nlatf,nlonf,2) - blending functions for grids 212 and 221
!
! attributes:
!   language: f90
!   machine:  ibm RS/6000 SP
!
!$$$
  use kinds, only: i_kind, r_kind
  use constants, only: zero, one, half, izero, ione
  use mpimod, only: npe, mpi_sum, mpi_itype, mpi_comm_world
  use gridmod, only: nlat,nlon,tll2xy, &
                     region_lon, region_lat, &
                     rlon_min_dd,rlon_max_dd, &
                     rlat_min_dd,rlat_max_dd
  use anberror, only: pf2aP1

  implicit none

! Declare passed variables
  integer(i_kind),intent(in):: mype,ngrds
  integer(i_kind),intent(out)::igbox(4,ngrds),igbox0f(4,ngrds)
  integer(i_kind),intent(out)::iref(nlat,nlon,ngrds)
  integer(i_kind),intent(out)::jref(nlat,nlon,ngrds)
  real(r_kind),   intent(out)::ensmask(nlat,nlon,ngrds)
  real(r_kind)   ,intent(out)::enscoeff(4,nlat,nlon,ngrds)
  real(r_kind),   intent(out)::gblend(pf2aP1%nlatf,pf2aP1%nlonf,2)

! Declare local variables
  integer(i_kind),parameter::ijadjust=4
  integer(i_kind) iy,jx,jxp
  integer(i_kind) i,j,kg,ii,jj,ierr8,ierror
  integer(i_kind) iarea(npe),iarea2(npe),iprod,ilateral,jlateral
  integer(i_kind) ilower,iupper,jleft,jright
  integer(i_kind) ilower_prev,iupper_prev,jleft_prev,jright_prev
  integer(i_kind) i1,i2,j1,j2,ij,mype1
  integer(i_kind) iimin(npe),iimax(npe),jjmin(npe),jjmax(npe)
  integer(i_kind) iimin2(npe),iimax2(npe),jjmin2(npe),jjmax2(npe)
  integer(i_kind) iimin0(3),iimax0(3),jjmin0(3),jjmax0(3)
  real(r_kind) rlat,rlon,alat1,elon1,ds,elonv,alatan,xg,yg
  real(r_kind) dxg,dyg,dxg1,dyg1,rad2dg
  real(r_kind) dlon,dlat
  real(r_kind) dlonmin,dlonmax,dlatmin,dlatmax
  real(r_kind) dist1,dist2
  real(r_kind) gblend_l(pf2aP1%nlonf,2)
  real(r_kind) gblend_r(pf2aP1%nlonf,2)
  real(r_kind) gblend_b(pf2aP1%nlatf,2)
  real(r_kind) gblend_t(pf2aP1%nlatf,2)
  real(r_kind) r360
  logical outside
  logical ltest,ltest1,ltest2,ltest3,ltest4
!*****************************************************************
  rad2dg=180._r_kind/acos(-one)
  r360=360._r_kind
!=================================================================
  enscoeff(:,:,:,:)=-1.e+20_r_kind
  ensmask(:,:,1:2)=-one
  ensmask(:,:,3)  = one  !model grid is always fully contained in global
!                         ensemble grid

  do kg=1,3

    if      (kg==1) then         !grid #212
      call set_grdparm212(iy,jx,jxp,alat1,elon1,ds,elonv,alatan)
    else if (kg==2) then         !grid #221
      call set_grdparm221(iy,jx,jxp,alat1,elon1,ds,elonv,alatan)
    else if (kg==3) then         !1dg x 1dg global grid
      iy=181
      jx=360
      jxp=jx+1
    end if

    do j=1,nlon
    do i=1,nlat

      ! latlon for the analysing grid
      rlat=region_lat(i,j)*rad2dg
      rlon=region_lon(i,j)*rad2dg
      if (rlon .lt. zero) rlon=rlon+r360

      ! correspoinding ensemble grid
      if (kg==1 .or. kg==2) then
        call w3fb11(rlat,rlon,alat1,elon1,ds,elonv,alatan,xg,yg)
      else if(kg==3) then
        xg=rlon+one
        if (rlon.ge.r360) xg=rlon+one-r360
        yg=rlat+90._r_kind+one
      end if

      dxg=xg-float(floor(xg))
      dyg=yg-float(floor(yg))
      dxg1=one-dxg
      dyg1=one-dyg

      if (xg .ge. one .and. xg .le. float(jxp) .and.  &
          yg .ge. one .and. yg .le. float(iy) ) then

        enscoeff(1,i,j,kg)=dxg1*dyg1
        enscoeff(2,i,j,kg)=dxg1*dyg
        enscoeff(3,i,j,kg)=dxg*dyg1
        enscoeff(4,i,j,kg)=dxg*dyg

        iref(i,j,kg)=floor(yg)
        jref(i,j,kg)=floor(xg)

        if (kg==1 .or. kg==2) ensmask(i,j,kg)=one

      end if

    end do
    end do
  end do

!==>determine rectangle of analysis grid that falls inside the ensemble grid

  do kg=1,2
    dlonmin=+huge(dlonmin)
    dlonmax=-huge(dlonmax)
    dlatmin=+huge(dlatmin)
    dlatmax=-huge(dlatmax)

    if      (kg==1) then         !grid #212
      call set_grdparm212(iy,jx,jxp,alat1,elon1,ds,elonv,alatan)
    else if (kg==2) then         !grid #221
      call set_grdparm221(iy,jx,jxp,alat1,elon1,ds,elonv,alatan)
    endif

    do j=1,iy
      yg=float(j)*one
      do i=1,jx
        xg=float(i)*one
        call w3fb12(xg,yg,alat1,elon1,ds,elonv,alatan,rlat,rlon,ierr8)
        rlon=rlon/rad2dg
        rlat=rlat/rad2dg
        call tll2xy(rlon,rlat,dlon,dlat,outside)
        dlon=min(rlon_max_dd,max(rlon_min_dd,dlon))
        dlat=min(rlat_max_dd,max(rlat_min_dd,dlat))
        dlonmin=min(dlonmin,dlon)
        dlonmax=max(dlonmax,dlon)
        dlatmin=min(dlatmin,dlat)
        dlatmax=max(dlatmax,dlat)
      end do
    end do

    i1=ceiling(dlatmin)
    i2=floor  (dlatmax)
    j1=ceiling(dlonmin)
    j2=floor  (dlonmax)

    if (mype==0) print*,'in ens_intpcoeffs_reg: kg, i1,i2,j1,j2=',kg, i1,i2,j1,j2

!==>adjust limits by trial and error

    ilateral=2
    jlateral=2
100 continue
    ilower=i1+ilateral
    iupper=i2-ilateral
    jleft=j1+jlateral
    jright=j2-jlateral
    ltest=any(ensmask(ilower:iupper,jleft:jright,kg).lt.zero)
    if (ltest) then
      ilateral=ilateral+2
      jlateral=jlateral+2
      goto 100
    endif
    ilateral=ilateral+4  !increase if necessary
    jlateral=jlateral+4

    if (mype==0) print*,'in ens_intpcoeffs_reg: kg,ilateral,jlateral=',kg,ilateral,jlateral

    ilower_prev=i1+ilateral
    iupper_prev=i2-ilateral
    jleft_prev =j1+jlateral
    jright_prev=j2-jlateral

    mype1=mype+1

    ij=0
    iarea(:)=izero
    iimin(:)=izero
    iimax(:)=izero
    jjmin(:)=izero
    jjmax(:)=izero
    do ilower=(i1+ilateral),i1,-1
      do iupper=(i2-ilateral),i2
        do jleft=(j1+jlateral),j1,-1
          do jright=(j2-jlateral),j2
            ij=ij+1
            if (mod(ij-1,npe) == mype)then
              ltest1=any(ensmask(ilower:ilower_prev,jleft:jright,kg).lt.zero)
              ltest2=any(ensmask(iupper_prev:iupper,jleft:jright,kg).lt.zero)
              ltest3=any(ensmask(ilower:iupper,jleft:jleft_prev,kg).lt.zero)
              ltest4=any(ensmask(ilower:iupper,jright_prev:jright,kg).lt.zero)
              if (.not.ltest1  .and. .not.ltest2 .and. .not.ltest3 .and. .not.ltest4) then
                iprod=(iupper-ilower)*(jright-jleft)
                if (iprod > iarea(mype1)) then
                  iarea(mype1)=iprod
                  iimin(mype1)=ilower
                  iimax(mype1)=iupper
                  jjmin(mype1)=jleft
                  jjmax(mype1)=jright
                end if
              end if
              ilower_prev=ilower
              iupper_prev=iupper
              jleft_prev =jleft
              jright_prev=jright
            end if
          end do
        end do
      end do
    end do

    iarea2(:)=izero
    iimin2(:)=izero
    iimax2(:)=izero
    jjmin2(:)=izero
    jjmax2(:)=izero

    call mpi_allreduce(iarea,iarea2,npe,mpi_itype, &
                       mpi_sum,mpi_comm_world,ierror)
    call mpi_allreduce(iimin,iimin2,npe,mpi_itype, &
                       mpi_sum,mpi_comm_world,ierror)
    call mpi_allreduce(iimax,iimax2,npe,mpi_itype, &
                       mpi_sum,mpi_comm_world,ierror)
    call mpi_allreduce(jjmin,jjmin2,npe,mpi_itype, &
                       mpi_sum,mpi_comm_world,ierror)
    call mpi_allreduce(jjmax,jjmax2,npe,mpi_itype, &
                       mpi_sum,mpi_comm_world,ierror)

    iprod=0
    do i=1,npe
      if (iarea2(i) > iprod) then
        iprod=iarea2(i)
        j=i
      end if
    end do

    iimin0(kg)=iimin2(j)
    iimax0(kg)=iimax2(j)
    jjmin0(kg)=jjmin2(j)
    jjmax0(kg)=jjmax2(j)

  end do

!check limits
  if (mype.eq.0) then
    do kg=1,2
      do i=iimin0(kg),iimax0(kg)
      do j=jjmin0(kg),jjmax0(kg)
        if (ensmask(i,j,kg) < zero) then
          print*,'in ens_intpcoeffs_reg: trouble: kg,i,j,ensmask(i,j,kg)=',&
          kg,i,j,ensmask(i,j,kg)
        end if
      end do
      end do
    end do
  end if

  iimin0(3)=1
  iimax0(3)=nlat
  jjmin0(3)=1
  jjmax0(3)=nlon

  do kg=1,3
    igbox(1,kg)=iimin0(kg)
    igbox(2,kg)=iimax0(kg)
    igbox(3,kg)=jjmin0(kg)
    igbox(4,kg)=jjmax0(kg)
    igbox0f(1,kg)=one+float((igbox(1,kg)-ione))/pf2aP1%grid_ratio_lat + ijadjust
    igbox0f(2,kg)=one+float((igbox(2,kg)-ione))/pf2aP1%grid_ratio_lat - ijadjust
    igbox0f(3,kg)=one+float((igbox(3,kg)-ione))/pf2aP1%grid_ratio_lon + ijadjust
    igbox0f(4,kg)=one+float((igbox(4,kg)-ione))/pf2aP1%grid_ratio_lon - ijadjust
  end do

!==> compute blending functions

  do i=1,pf2aP1%nlatf
    dist1=float(igbox0f(1,1)-i)
    dist2=float(i-igbox0f(2,1))
    gblend_b(i,1)=half*(one-tanh(dist1)) !relax to zero
    gblend_t(i,1)=half*(one-tanh(dist2)) !outside 212 grid

    dist1=float(igbox0f(1,2)-i)
    dist2=float(i-igbox0f(2,2))
    gblend_b(i,2)=half*(one-tanh(dist1)) !relax to zero
    gblend_t(i,2)=half*(one-tanh(dist2)) !outside 221 grid
  end do

  do j=1,pf2aP1%nlonf
    dist1=float(igbox0f(3,1)-j)
    dist2=float(j-igbox0f(4,1))
    gblend_l(j,1)=half*(one-tanh(dist1)) !relax to zero
    gblend_r(j,1)=half*(one-tanh(dist2)) !outside 212 grid

    dist1=float(igbox0f(3,2)-j)
    dist2=float(j-igbox0f(4,2))
    gblend_l(j,2)=half*(one-tanh(dist1)) !relax to zero
    gblend_r(j,2)=half*(one-tanh(dist2)) !outside 221 grid
  end do

  do i=1,pf2aP1%nlatf
  do j=1,pf2aP1%nlonf
    gblend(i,j,1)=gblend_b(i,1)*gblend_t(i,1)*gblend_l(j,1)*gblend_r(j,1)
    gblend(i,j,2)=gblend_b(i,2)*gblend_t(i,2)*gblend_l(j,2)*gblend_r(j,2)
  end do
  end do

  if(mype==0) then
    open(94,file='gblend.dat',form='unformatted')
    write(94) gblend
    close(94)
  end if

end subroutine ens_intpcoeffs_reg
!=======================================================================
!=======================================================================
subroutine fillanlgrd(workin,ngrds,igrid,nx,ny,workout, &
                       iref,jref,igbox,enscoeff,mype)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    fillanlgrd
!   prgmmr: pondeca          org: np22                date: 2007-04-05
!
! abstract: perform horizontal interpolation of ensemble field to analysis
!           grid.
!
! program history log:
!   2007-04-05  pondeca
!
!   input argument list:
!     mype           - mpi task id
!     workin(nx,ny)  - ensemble field
!     igrid          - grid number. currently 212,221 or 3
!     nx,ny          - horizontal dimensions of ensemble field
!     ngrds          - number of supported ensemble grids. currently 3
!     enscoeff       - coefficients of bilienar interpolation from
!                      ensemble grid to analysis grid
!     igbox          - i and j corner values of portion of anl grid that
!                      falls completly inside e-grid
!
!   output argument list:
!    workout(nlat,nlon) - ensemble field on analysis grid
!
! attributes:
!   language: f90
!   machine:  ibm RS/6000 SP
!
!$$$
  use kinds, only: i_kind, r_single, r_kind
  use gridmod, only: nlat,nlon
  implicit none


! Declare passed variables
  integer(i_kind),intent(in):: mype,igrid,ngrds,nx,ny,igbox(4,ngrds)
  integer(i_kind),intent(in):: iref(nlat,nlon,ngrds)
  integer(i_kind),intent(in):: jref(nlat,nlon,ngrds)
  real(r_kind)   ,intent(in):: enscoeff(4,nlat,nlon,ngrds)
  real(r_single),dimension(nx,ny),intent(in)::workin
  real(r_single),dimension(nlat,nlon),intent(inout)::workout

! Declare local variables
  integer(i_kind) i,j,kg,ii,jj,iip,jjp,nxp
  integer(i_kind) nxs,nxe,nys,nye,nxb,nyb

  real(r_single),allocatable,dimension(:,:):: tworkin
  real(r_single),allocatable,dimension(:,:):: asmall

!* *****************************************************************************
  select case(igrid)
    case(212); kg=1
    case(221); kg=2
    case(  3); kg=3
    case default
      print*,'in fillanlgrd: warning, unknown grid, igrid=',igrid
  end select

! print*,'in fillanlgrd: igrid,nx,ny=',igrid,nx,ny

  nxp=nx
  if (kg ==3) nxp=nx+1

  allocate(tworkin(ny,nxp))

  do i=1,ny
  do j=1,nx
     tworkin(i,j)=workin(j,i)
  enddo
  enddo

  if (kg == 3) tworkin(:,nxp)=tworkin(:,1)

  nxs=igbox(3,kg)
  nxe=igbox(4,kg)
  nys=igbox(1,kg)
  nye=igbox(2,kg)

  allocate(asmall(nys:nye,nxs:nxe))

  do i=nys,nye
  do j=nxs,nxe

     ii=iref(i,j,kg)
     jj=jref(i,j,kg)
     iip=min(ii+1,ny)
     jjp=min(jj+1,nxp)
     asmall(i,j)=real(enscoeff(1,i,j,kg)*real(tworkin(ii ,jj ),r_kind)+ &
                      enscoeff(2,i,j,kg)*real(tworkin(iip,jj ),r_kind)+ &
                      enscoeff(3,i,j,kg)*real(tworkin(ii ,jjp),r_kind)+ &
                      enscoeff(4,i,j,kg)*real(tworkin(iip,jjp),r_kind),r_single)
  enddo
  enddo

  if (igrid == 3) then
    workout(:,:)=asmall(:,:)  !this should be ok. index ranges are the same for this case
  else
    call ens_mirror(asmall,workout,nxs,nxe,nys,nye,nlon,nlat)
  endif

  deallocate(tworkin)
  deallocate(asmall)
end subroutine fillanlgrd
!=======================================================================
!=======================================================================
subroutine ens_mirror(asmall,alarge,nxs,nxe,nys,nye,nxb,nyb)
!-------------------------------------------------------------------------
!    NOAA/NCEP, National Centers for Environmental Prediction GSI        !
!-------------------------------------------------------------------------
!$$$   subprogram documentation block
!                .      .    .                                       .
! subprogram:    mirror
! prgmmr: pondeca          org: np23                date: 2007-03-01
!
! abstract: given a grid alarge that contains the smaller grid asmall,
!           polulate alarge using the values of asmall. simply copy the
!           the field values from asmall to alarge where the two grids
!           overlap. then starting at each boundary of asmall, perform
!           a mirroring of the field and populate the remaining points
!           of alarge.
!
! program history log:
!   2007-03-01  pondeca
!
! uses:
       use kinds, only: i_kind,r_single
       use constants, only: zero_single

       implicit none

! Declare passed variables
       integer(i_kind),intent(in):: nxs,nxe,nys,nye
       integer(i_kind),intent(in):: nxb,nyb

       real(r_single),intent(in):: asmall(nys:nye,nxs:nxe)
       real(r_single),intent(inout):: alarge(1:nyb,1:nxb)

! Declare local variables
       integer(i_kind) i,j,m,n,k
!*****************************************************************

!==>   use values from small domain to populate big domain where
!      there is overlapping

       alarge(:,:)=zero_single
       do j=nxs,nxe
       do i=nys,nye
          alarge(i,j)=asmall(i,j)
       enddo
       enddo

!==> start by mirroring field in the i-direction

       do j=nxs,nxe
          do m=nye+1,nyb
             k=(m-nye-1)/(nye-nys)
             n=2*(nye+k*(nye-nys))-m
             alarge(m,j)=alarge(n,j)
          enddo

          do m=nys-1,1,-1
             k=(nys-m-1)/(nye-nys)
             n=2*(nys-k*(nye-nys))-m
             alarge(m,j)=alarge(n,j)
          enddo
       enddo

!==> fill out remaining part of large grid

       do i=1,nyb
          do m=nxs-1,1,-1
             k=(nxs-m-1)/(nxe-nxs)
             n=2*(nxs-k*(nxe-nxs))-m
             alarge(i,m)=alarge(i,n)
          enddo

          do m=nxe+1,nxb
             k=(m-nxe-1)/(nxe-nxs)
             n=2*(nxe+k*(nxe-nxs))-m
             alarge(i,m)=alarge(i,n)
          enddo
       enddo

end subroutine ens_mirror
!=======================================================================
subroutine pges_minmax(mype,pmin,pmax)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    pges_minmax
!   prgmmr: pondeca          org: np22                date: 2007-04-05
!
! abstract: computes vertical profiles of minimum an maximum layer
!           values of the guess pressure field. values in hPa
!
! program history log:
!   2007-04-05  pondeca
!
!   input argument list:
!     mype     - mpi task id
!
!   output argument list:
!     pmin(nsig) - vertical profile of layer minimum guess pressure value
!     pmax(nsig) - vertical profile of layer maximum guess pressure value
!
! attributes:
!   language: f90
!   machine:  ibm RS/6000 SP
!
!$$$
  use kinds, only: i_kind, r_kind
  use gridmod, only: lat1,lon1,nsig
  use guess_grids, only: ges_prsl
  use mpimod,only: mpi_real8, mpi_min, mpi_max, mpi_comm_world, strip
  implicit none

! Declare passed variables
  integer(i_kind),intent(in):: mype
  real(r_kind),intent(out):: pmin(nsig),pmax(nsig)

! Declare local variables
  integer(i_kind):: k,ierror
  real(r_kind):: p3d(lat1,lon1,nsig)
  real(r_kind):: p1,p2

  call strip(ges_prsl,p3d,nsig)

  do k=1,nsig
     p1=minval(p3d(:,:,k))
     p2=maxval(p3d(:,:,k))
     call mpi_allreduce(p1,pmin(k),1,mpi_real8,mpi_min,mpi_comm_world,ierror)
     call mpi_allreduce(p2,pmax(k),1,mpi_real8,mpi_max,mpi_comm_world,ierror)
  enddo

  pmin(:)=pmin(:)*10._r_kind
  pmax(:)=pmax(:)*10._r_kind

  if (mype.eq.0) then
    do k=1,nsig
      print*,'in pges_minmax,k,pmin(k),pmax(k)=',k,pmin(k),pmax(k)
    enddo
  endif

end subroutine pges_minmax
!=======================================================================
!=======================================================================
subroutine check_32primes(n,lprime)
!
!    check to see i n has only primes of 3 and 2
!
  use kinds, only: i_kind
  implicit none

  integer(i_kind) n,nn,nfax,ii
  logical lprime

  lprime=.false.
  nfax = 0
  nn=n

!
! check for factors of 3
!
  do 10 ii = 1,20
    if (nn.eq.3*(nn/3)) then
      nfax = nfax+1
      nn = nn/3
    else
      go to 20
    end if
  10 continue
  20 continue
!
! check for factors of 2
!
  do 30 ii = nfax+1,20
    if (nn .eq. 2*(nn/2)) then
      nfax = nfax +1
      nn = nn/2
    else
      go to 40
    end if
  30 continue
  40 continue
  if (nn.eq.1) lprime=.true.

  return

end subroutine check_32primes
!=======================================================================
!=======================================================================
subroutine intp_spl(xi,yi,xo,yo,ni,no)
!$$$  subprogram documentation block
!                .      .    .                                       .
! subprogram:    intp_spl
!   prgmmr: sato             org: np22                date: 2008-03-31
!
! abstract: 3rd-order spline inter/extra-polation
!
! program history log:
!   2008-03-31  sato
!
!   input argument list:
!     xi - input x values
!     yi - input y values
!     xo - x valurs for y output
!     ni - input dimension
!     no - output dimension
!
!   output argument list:
!     yo - output y values
!
! attributes:
!   language: f90
!   machine:  ibm RS/6000 SP
!
!$$$
  use kinds, only: i_kind, r_kind, r_single
  implicit none

  integer,intent(in):: ni,no

  real(r_kind),intent(in):: xi(ni)
  real(r_kind),intent(in):: yi(ni)

  real(r_kind),intent(in) :: xo(no)
  real(r_kind),intent(out):: yo(no)

  real(r_kind),dimension(ni):: hi,bi,di,gi,ui,ri,pi,qi,si
  real(r_kind):: xe
  integer(i_kind):: k,kk,k0

  do k=1,ni-1
    hi(k)=xi(k+1)-xi(k)
  end do

  do k=2,ni-1
    bi(k)=2.0*(hi(k)+hi(k-1))
    di(k)=3.0*((yi(k+1)-yi(k))/hi(k)-(yi(k)-yi(k-1))/hi(k-1))
  end do

  gi(2)=hi(2)/bi(2)
  do k=3,ni-1
    gi(k)=hi(k)/(bi(k)-hi(k-1)*gi(k-1))
  end do

  ui(2)=di(2)/bi(2)
  do k=3,ni-1
    ui(k)=(di(k)-hi(k-1)*ui(k-1))/(bi(k)-hi(k-1)*gi(k-1))
  end do

  ri(ni)=0.0
  do k=ni-1,2,-1
    ri(k)=ui(k)-gi(k)*ri(k+1)
  end do
  ri(1)=0.0

  do k=1,ni-1
    pi(k)=yi(k)
    qi(k)=(yi(k+1)-yi(k))/hi(k)-hi(k)*(ri(k+1)+2.0*ri(k))/3.0
    si(k)=(ri(k+1)-ri(k))/(3.0*hi(k))
  end do

  do kk=1,no
    yo(kk)=huge(yo(kk))

! NOTE
! The lower extrapolation must be not so far from 1000mb. -> Extrapolation
! But the upper extrapolation might be far from the top level for Q. -> Use top end values
!
    if     (xo(kk)>=xi(1) ) then
!     yo(kk)=yi(1)  ! use the end value
      k0=1          ! extrapolation
    else if(xo(kk)<=xi(ni)) then
      yo(kk)=yi(ni) ! use the end value
!     k0=ni-1       ! extrapolation
    else
      do k=1,ni-1
        if( xo(kk)<xi(k) .and. xo(kk)>=xi(k+1) ) then
          k0=k
          exit
        end if
      end do
    end if
    if(yo(kk)==huge(yo(kk))) then
      xe=xo(kk)-xi(k0)
      yo(kk)=pi(k0)+qi(k0)*xe+ri(k0)*xe**2+si(k0)*xe**3
    end if
  end do
end subroutine intp_spl

subroutine ens_fill(ur,na,nb,u,nxx,ny,itap,no_wgt_in)
  use kinds, only: i_kind, r_single, r_kind
  use constants, only: zero, one
  implicit none

  integer(i_kind)::nxx,ny,na,nb,itap
  real(r_single):: u(nxx,ny)
  real(r_single):: ur(na,nb)
  real(r_kind):: wt(itap)
  logical,intent(in):: no_wgt_in

  real(r_kind):: pionp1,xi
  integer(i_kind)::i,j,im,jm,ip,jp
  integer(i_kind)::nah,nbh,naq,nbq,ndx,ndxh,ndy,ndyh,ndj,ndi,ndip,ndjp,ndipx
  logical:: no_wgt

  no_wgt=.false.
  if(no_wgt_in) no_wgt=.true.

  pionp1=4.*atan(1.)/float(itap+1)

  do i=1,itap
    xi=float(i)
    wt(i)=0.5+0.5*cos(pionp1*xi)
  enddo

  if(no_wgt) wt=one

  nah=na/2; nbh=nb/2
  naq=na/4; nbq=nb/4

  ndx =nah-nxx
  ndxh=ndx/2
  ndy =nbh-ny
  ndyh=ndy/2

  ur=zero

  ndj=nbq+ndyh
  ndi=naq+ndxh

!!!!!!! inner !!!!!
  do j=1,ny
    jp=j+ndj
    do i=1,nxx
      ip=i+ndi
      ur(ip,jp)= u(i,j)
    end do
  end do

!!!!!!! lower !!!!!
  ndjp=ndj+1
  do j=1,itap
    jm=ndjp-j
    do i=ndi+1,ndi+nxx
      ur(i,jm)=ur(i,ndjp)*wt(j)
    end do
  end do

!!!!!!! upper !!!!!
  ndjp=ndj+ny
  do j=1,itap
    jp=ndjp+j
    do i=ndi+1,ndi+nxx
      ur(i,jp)=ur(i,ndjp)*wt(j)
    end do
  end do

!!!!!!! left+right  !!!!!
  ndip=ndi+1
  ndipx=ndi+nxx
  do j=ndj+1-itap,ndj+ny+itap
    do i=1,itap
      im=ndip-i
      ur(im,j)=ur(ndip ,j)*wt(i)
    end do
    do i=1,itap
      ip=ndipx+i
      ur(ip,j)=ur(ndipx,j)*wt(i)
    end do
  end do

  return
end subroutine ens_fill

subroutine ens_unfill(ur,na,nb,u,nxx,ny)
  use kinds, only: i_kind, r_single, r_kind
  implicit none

  integer(i_kind),intent(in)::na,nb,nxx,ny
  real(r_single):: u(nxx,ny)
  real(r_single):: ur(na,nb)
  real(r_kind):: uw(na/2,nb/2)
  integer(i_kind)::i,j,im,jm,ip,jp
  integer(i_kind)::nah,nbh,naq,nbq,ndx,ndxh,ndy,ndyh,ndj,ndi

  nah=na/2; nbh=nb/2
  naq=na/4; nbq=nb/4

  ndx =nah-nxx
  ndxh=ndx/2
  ndy =nbh-ny
  ndyh=ndy/2

  ndj=nbq+ndyh
  ndi=naq+ndxh

  do j=1,ny
    jp=j+ndj
    do i=1,nxx
      ip=i+ndi
      u(i,j)=ur(ip,jp)
    end do
  end do

  return
end subroutine ens_unfill

end module aniso_ens_util