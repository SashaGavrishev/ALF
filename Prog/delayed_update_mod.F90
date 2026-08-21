!  Copyright (C) 2016 - 2022 The ALF project
!
!     The ALF project is free software: you can redistribute it and/or modify
!     it under the terms of the GNU General Public License as published by
!     the Free Software Foundation, either version 3 of the License, or
!     (at your option) any later version.
!
!     The ALF project is distributed in the hope that it will be useful,
!     but WITHOUT ANY WARRANTY; without even the implied warranty of
!     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!     GNU General Public License for more details.
!
!     You should have received a copy of the GNU General Public License
!     along with ALF.  If not, see http://www.gnu.org/licenses/.
!
!     Under Section 7 of GPL version 3 we require you to fulfill the following additional terms:
!
!     - It is our hope that this program makes a contribution to the scientific community. Being
!       part of that community we feel that it is reasonable to require you to give an attribution
!       back to the original authors if you have benefitted from this program.
!       Guidelines for a proper citation can be found on the project's homepage
!       http://alf.physik.uni-wuerzburg.de .
!
!     - We require the preservation of the above copyright notice and this license in all original files.
!
!     - We prohibit the misrepresentation of the origin of the original source files. To obtain
!       the original source files please visit the homepage http://alf.physik.uni-wuerzburg.de .
!
!     - If you make substantial changes to the program we require you to either consider contributing
!       to the ALF project or to mark your material in a reasonable way as different from the original version.

!--------------------------------------------------------------------
!> @brief
!> Holds the Green's function in factored form across one time slice, so an
!> accepted flip appends a column pair instead of touching the whole matrix.
!>
!> @details
!> Every accepted single-site flip applies a rank-d update to the whole Green's
!> function (upgrade_mod). That is level-2: it streams Ndim**2 complex entries to
!> do O(d*Ndim**2) flops, so it is bound by memory bandwidth -- and a production
!> node runs one such chain per core against one memory system.
!>
!> The next proposal does not need the updated matrix. It needs the d x d block
!> on the operator's support for the ratio, and on acceptance d rows and d
!> columns. Never the whole matrix. So hold
!>
!>     G = G_stale + X * Y^T,   X, Y of shape (Ndim, k)
!>
!> and pay Ndim**2 only once every k accepted flips, as a level-3 ZGEMM. Traffic
!> per accepted flip falls from ~2*Ndim**2 to ~2*d*Ndim*k + 2*Ndim**2/k, least
!> near k = sqrt(Ndim).
!>
!> **Scope: one time slice's sequential vertex loop.** Wrapgr_mod opens the region
!> after the hopping propagator and closes it before the next one, so nothing in
!> stabilisation, measurement or the global-move machinery ever sees a factored
!> Green's function, and the accumulated error is flushed exactly once per slice
!> rather than growing to Nwrap scale. What runs *inside* the loop is the vertex
!> conjugation Op_Wrapup/Op_Wrapdo, which is row/column-restricted and so applies
!> to the panels for O(d*k); see Op_Wrap_panels in Operator_mod.
!>
!> Deliberately free of Hamiltonian_main: every dimension is passed in, so the
!> module links against Operator_mod and Fields_mod alone and a unit test does
!> not have to link most of ALF.
!>
!> Off by default. ALF_DELAY_K enables it; see delay_depth.
!--------------------------------------------------------------------

module delayed_update_mod
   use Operator_mod
   use runtime_error_mod
   use iso_fortran_env, only: error_unit
   implicit none

   private
   public :: delay_alloc, delay_dealloc, delay_depth, delay_active
   public :: delay_assert_inactive, delay_open, delay_close
   public :: delay_block, delay_row, delay_col, delay_append, delay_flush
   public :: delay_wrap, delay_pending, delay_verify_on

   ! Panels and their live column count, one set per flavour. Allocated once
   ! beside Wrapgr_alloc rather than per slice: at Ndim = 2048, k = 32, dmax = 2
   ! and N_FL = 2 this is ~4.5 MB against 67 MB for one Green's function.
   Complex (Kind=Kind(0.d0)), private, save, allocatable :: xp(:,:,:), yp(:,:,:)
   Integer,                   private, save, allocatable :: ncol(:)

   Integer, private, save :: kmax    = 0     !> Flush threshold, the k of the scheme
   Integer, private, save :: panel_w = 0     !> Allocated width, kmax + dmax
   Integer, private, save :: ndim_s  = 0
   Integer, private, save :: nfl_s   = 0
   Logical, private, save :: active  = .false.

   ! Parsed once from ALF_DELAY_K: 0 disables, > 0 fixes the depth, -1 means
   ! "auto" and resolves against Ndim. -2 is "not yet read".
   Integer, private, save :: k_request = -2
   Integer, private, parameter :: K_AUTO = -1
   Integer, private, parameter :: K_UNREAD = -2

   ! ALF_DELAY_VERIFY: carry a second Green's function through the slice, updated
   ! immediately, and compare the two when the region closes.
   !
   ! This is the instrument for the one risk the cost model explicitly does not
   ! measure. The immediate scheme reads an exactly updated row and column; the
   ! delayed one reconstructs them as a stale value plus c panel products, and
   ! cancellation there is the failure mode -- sharpest at
   ! v(P(n),n) = 1 - G(P(n),P(n)) and at the reciprocal in the Woodbury solve,
   ! where a small denominator amplifies whatever the reconstruction carried in.
   !
   ! An end-to-end run already answers "did the physics change"; what this adds
   ! is *where*, per reconstruction, so a discrepancy that grows with k or with
   ! Ndim can be seen growing rather than inferred from a final observable.
   !
   ! **The comparison is at the accessors, not at the flush.** Comparing the
   ! flushed matrix against the shadow measures nothing: the shadow is fed the
   ! same update columns the delayed arm computed, so a wrong reconstruction
   ! sends both the same way and they agree while both are wrong. Verified by
   ! mutation -- deleting the row correction left the flush comparison at 3e-16.
   ! What has to be checked is each reconstructed row, column and block against
   ! the shadow *at the moment it is handed out*, which is the quantity the
   ! Woodbury solve then consumes.
   !
   ! Development only, and off by default: it applies every update twice, wraps a
   ! second full matrix per vertex and compares a row and a column per accepted
   ! flip, so it is slower than the immediate scheme it exists to check.
   Logical, private, save :: verify      = .false.
   Logical, private, save :: verify_read = .false.
   Complex (Kind=Kind(0.d0)), private, save, allocatable :: gshadow(:,:,:)

contains

!--------------------------------------------------------------------
!> @brief
!> Delay depth for this run, 0 when the delayed update is disabled.
!> @details
!> ALF_DELAY_K, read once and cached, following ALF_UPDATE_SAMPLE in
!> upgrade_mod. Unset or "0" disables it -- the default, so a stock build takes
!> the pre-existing path and reproduces earlier results byte for byte. A positive
!> integer fixes the depth. "auto" resolves to a power of two near sqrt(Ndim),
!> which is where the traffic model has its optimum: 8 at Ndim = 72, 16 at 200,
!> 32 at 1152 and 2048.
!>
!> The auto ladder is provisional -- it encodes a measurement whose magnitudes are
!> order-of-magnitude only, and is a starting point for a wall-clock sweep rather
!> than a conclusion.
!>
!> Not a simulation parameter, deliberately: it would enter the parameter hash and
!> so repoint sim_dir away from existing data, for a knob that changes no physics.
!> Control writes the resolved depth to the info file instead, so a run still says
!> which path produced it.
!--------------------------------------------------------------------
   integer function delay_depth(Ndim)
      implicit none
      integer, intent(in) :: Ndim
      character(len=32) :: text
      integer :: length, status, value, k

      if (k_request == K_UNREAD) then
         k_request = 0
         call get_environment_variable("ALF_DELAY_K", text, length, status)
         if (status == 0 .and. length > 0) then
            if (trim(adjustl(text(1:length))) == "auto" .or. &
              & trim(adjustl(text(1:length))) == "AUTO") then
               k_request = K_AUTO
            else
               read (text(1:length), *, iostat=status) value
               if (status == 0 .and. value >= 0) k_request = value
            endif
         endif
      endif

      if (k_request == K_AUTO) then
         ! Nearest power of two to sqrt(Ndim), clamped to [8, 32]. Below 8 the
         ! flush dominates; above 32 the per-proposal ratio correction, which is
         ! O(d**2*k) and paid on rejected proposals too, starts to bite.
         k = 2**nint(log(sqrt(real(Ndim, Kind(0.d0))))/log(2.d0))
         delay_depth = min(32, max(8, k))
      else
         delay_depth = k_request
      endif
   end function delay_depth

!--------------------------------------------------------------------
!> @brief
!> Whether the shadow Green's function is being carried; see `verify`.
!--------------------------------------------------------------------
   logical function delay_verify_on()
      implicit none
      character(len=32) :: text
      integer :: length, status, value
      if (.not. verify_read) then
         verify_read = .true.
         verify = .false.
         call get_environment_variable("ALF_DELAY_VERIFY", text, length, status)
         if (status == 0 .and. length > 0) then
            read (text(1:length), *, iostat=status) value
            if (status == 0 .and. value > 0) verify = .true.
         endif
      endif
      delay_verify_on = verify
   end function delay_verify_on

!--------------------------------------------------------------------
!> @brief
!> Book one reconstruction discrepancy, scaled by the matrix it came from.
!> @details
!> Relative rather than absolute, so the figure is comparable across sizes,
!> slices and flavours -- which is the point, since the question is whether it
!> grows with k or with Ndim.
!--------------------------------------------------------------------
   subroutine verify_book(nf, worst)
      use Control, only: Control_delay_verify
      implicit none
      integer, intent(in) :: nf
      real (Kind=Kind(0.d0)), intent(in) :: worst
      real (Kind=Kind(0.d0)) :: scale
      scale = maxval(abs(gshadow(:,:,nf)))
      call Control_delay_verify(worst/max(scale, 1.d-300))
   end subroutine verify_book

!--------------------------------------------------------------------
!> @brief
!> Whether a factored region is currently open.
!--------------------------------------------------------------------
   logical function delay_active()
      implicit none
      delay_active = active
   end function delay_active

!--------------------------------------------------------------------
!> @brief
!> Live column count for one flavour, for tests and diagnostics.
!--------------------------------------------------------------------
   integer function delay_pending(nf)
      implicit none
      integer, intent(in) :: nf
      delay_pending = 0
      if (allocated(ncol)) delay_pending = ncol(nf)
   end function delay_pending

!--------------------------------------------------------------------
!> @brief
!> Fail loudly if a factored region is open where the caller cannot cope.
!> @details
!> Wrapgr_PlaceGR and Wrapgr_Random_update read and copy the whole Green's
!> function (GR_st = Gr, Gr = GR_st for the multi-flip restore), which a factored
!> one would silently corrupt. Today neither can run inside the region -- both are
!> reached only outside the sequential vertex loop -- so this asserts an invariant
!> rather than handling a case. A future caller that breaks it stops here instead
!> of quietly reading a stale matrix.
!--------------------------------------------------------------------
   subroutine delay_assert_inactive(where)
      implicit none
      character(len=*), intent(in) :: where
      if (active) then
         write(error_unit,*) 'delayed_update: ', trim(where), &
            & ' reached with a factored Green function open'
         Call Terminate_on_error(ERROR_GENERIC,__FILE__,__LINE__)
      endif
   end subroutine delay_assert_inactive

!--------------------------------------------------------------------
!> @brief
!> Allocate the panels. No-op when the delay is disabled.
!> @param[in] dmax Largest wrap support, maxval(Op_V(:,:)%N).
!> @details
!> The width is kmax + dmax, not kmax: a flip is appended first and the panel
!> flushed afterwards, so the last append of a period must fit.
!>
!> dmax is the *wrap* support Op%N, not the update support Op%N_non_zero. The two
!> differ (N_non_zero <= N) and the conjugation touches all N rows.
!--------------------------------------------------------------------
   subroutine delay_alloc(Ndim, N_FL, dmax)
      implicit none
      integer, intent(in) :: Ndim, N_FL, dmax

      kmax = delay_depth(Ndim)
      if (kmax <= 0) return

      ndim_s  = Ndim
      nfl_s   = N_FL
      panel_w = kmax + max(dmax, 1)
      allocate (xp(Ndim, panel_w, N_FL), yp(Ndim, panel_w, N_FL))
      allocate (ncol(N_FL))
      ncol   = 0
      active = .false.
      if (delay_verify_on()) allocate (gshadow(Ndim, Ndim, N_FL))
   end subroutine delay_alloc

   subroutine delay_dealloc()
      implicit none
      if (allocated(xp))      deallocate (xp)
      if (allocated(yp))      deallocate (yp)
      if (allocated(ncol))    deallocate (ncol)
      if (allocated(gshadow)) deallocate (gshadow)
      kmax   = 0
      active = .false.
   end subroutine delay_dealloc

!--------------------------------------------------------------------
!> @brief
!> Open a factored region. No-op when the delay is disabled.
!--------------------------------------------------------------------
   subroutine delay_open(GR)
      implicit none
      Complex (Kind=Kind(0.d0)), intent(in) :: GR(:,:,:)
      if (kmax <= 0) return
      ncol   = 0
      active = .true.
      ! The shadow starts from the same matrix and is then carried forward by
      ! the immediate scheme, so any divergence at delay_close is the delay's.
      if (verify) gshadow = GR
   end subroutine delay_open

!--------------------------------------------------------------------
!> @brief
!> Flush every flavour into GR and close the region.
!> @details
!> Whatever is still pending has to be paid for: leaving it out would credit the
!> chain with updates it never applied.
!--------------------------------------------------------------------
   subroutine delay_close(GR)
      implicit none
      Complex (Kind=Kind(0.d0)), intent(inout) :: GR(:,:,:)
      integer :: nf
      real (Kind=Kind(0.d0)) :: worst
      if (.not. active) return
      do nf = 1, nfl_s
         call delay_flush(nf, GR)
      enddo
      if (verify) then
         ! Only the flush is under test here -- the shadow received the same
         ! update columns, so this cannot see a bad reconstruction, and the
         ! accessors are where that is checked. Kept because it does catch a
         ! dropped or double-counted flush, which the accessors would not.
         do nf = 1, nfl_s
            worst = maxval(abs(GR(:,:,nf) - gshadow(:,:,nf)))
            call verify_book(nf, worst)
         enddo
      endif
      active = .false.
   end subroutine delay_close

!--------------------------------------------------------------------
!> @brief
!> Apply the pending columns of one flavour to GR: G_stale += X*Y^T.
!--------------------------------------------------------------------
   subroutine delay_flush(nf, GR)
      implicit none
      integer, intent(in) :: nf
      Complex (Kind=Kind(0.d0)), intent(inout) :: GR(:,:,:)
      Complex (Kind=Kind(0.d0)) :: one
      if (kmax <= 0) return
      if (ncol(nf) <= 0) return
      one = cmplx(1.d0, 0.d0, Kind(0.d0))
      call ZGEMM('N', 'T', ndim_s, ndim_s, ncol(nf), one, xp(1,1,nf), ndim_s, &
         &       yp(1,1,nf), ndim_s, one, GR(1,1,nf), ndim_s)
      ncol(nf) = 0
   end subroutine delay_flush

!--------------------------------------------------------------------
!> @brief
!> The d x d block of the *current* Green's function on the operator's support.
!> @details
!> blk(n,m) = G(P(n), P(m)) = G_stale(P(n),P(m)) + sum_c X(P(n),c)*Y(P(m),c).
!>
!> O(d**2 * c), and paid on every proposal including the rejected ones -- this is
!> the cost the delay adds, and the reason a very large k stops paying.
!--------------------------------------------------------------------
   subroutine delay_block(nf, GR, P, d, blk)
      implicit none
      integer, intent(in) :: nf, d, P(d)
      Complex (Kind=Kind(0.d0)), intent(in)  :: GR(:,:,:)
      Complex (Kind=Kind(0.d0)), intent(out) :: blk(d,d)
      real (Kind=Kind(0.d0)) :: worst
      integer :: n, m, c
      c = ncol(nf)
      do m = 1, d
         do n = 1, d
            blk(n,m) = GR(P(n), P(m), nf)
         enddo
      enddo
      if (c > 0) then
         do m = 1, d
            do n = 1, d
               blk(n,m) = blk(n,m) + sum(xp(P(n),1:c,nf)*yp(P(m),1:c,nf))
            enddo
         enddo
      endif
      if (verify) then
         worst = 0.d0
         do m = 1, d
            do n = 1, d
               worst = max(worst, abs(blk(n,m) - gshadow(P(n),P(m),nf)))
            enddo
         enddo
         call verify_book(nf, worst)
      endif
   end subroutine delay_block

!--------------------------------------------------------------------
!> @brief
!> d rows of the current Green's function: rows(i,l) = G(P(l), i).
!> @details
!> Stale row plus Y * X(P(l),:)^T, one ZGEMV each. The stale part is a strided
!> read of a column-major matrix -- Ndim cache lines for Ndim*16 bytes -- which is
!> exactly the traffic the delay exists to amortise.
!--------------------------------------------------------------------
   subroutine delay_row(nf, GR, P, d, rows)
      implicit none
      integer, intent(in) :: nf, d, P(d)
      Complex (Kind=Kind(0.d0)), intent(in)  :: GR(:,:,:)
      Complex (Kind=Kind(0.d0)), intent(out) :: rows(ndim_s, d)
      Complex (Kind=Kind(0.d0)) :: one, tmp(max(ncol(nf),1))
      real (Kind=Kind(0.d0)) :: worst
      integer :: i, l, c
      c   = ncol(nf)
      one = cmplx(1.d0, 0.d0, Kind(0.d0))
      do l = 1, d
         do i = 1, ndim_s
            rows(i,l) = GR(P(l), i, nf)
         enddo
         if (c > 0) then
            tmp(1:c) = xp(P(l), 1:c, nf)
            call ZGEMV('N', ndim_s, c, one, yp(1,1,nf), ndim_s, tmp, 1, one, rows(1,l), 1)
         endif
      enddo
      if (verify) then
         worst = 0.d0
         do l = 1, d
            do i = 1, ndim_s
               worst = max(worst, abs(rows(i,l) - gshadow(P(l),i,nf)))
            enddo
         enddo
         call verify_book(nf, worst)
      endif
   end subroutine delay_row

!--------------------------------------------------------------------
!> @brief
!> d columns of the current Green's function: cols(i,l) = G(i, P(l)).
!--------------------------------------------------------------------
   subroutine delay_col(nf, GR, P, d, cols)
      implicit none
      integer, intent(in) :: nf, d, P(d)
      Complex (Kind=Kind(0.d0)), intent(in)  :: GR(:,:,:)
      Complex (Kind=Kind(0.d0)), intent(out) :: cols(ndim_s, d)
      Complex (Kind=Kind(0.d0)) :: one, tmp(max(ncol(nf),1))
      real (Kind=Kind(0.d0)) :: worst
      integer :: l, c
      c   = ncol(nf)
      one = cmplx(1.d0, 0.d0, Kind(0.d0))
      do l = 1, d
         call ZCOPY(ndim_s, GR(1, P(l), nf), 1, cols(1,l), 1)
         if (c > 0) then
            tmp(1:c) = yp(P(l), 1:c, nf)
            call ZGEMV('N', ndim_s, c, one, xp(1,1,nf), ndim_s, tmp, 1, one, cols(1,l), 1)
         endif
      enddo
      if (verify) then
         worst = 0.d0
         do l = 1, d
            do c = 1, ndim_s
               worst = max(worst, abs(cols(c,l) - gshadow(c,P(l),nf)))
            enddo
         enddo
         call verify_book(nf, worst)
      endif
   end subroutine delay_col

!--------------------------------------------------------------------
!> @brief
!> Apply a rank-d update by appending d column pairs; flush when full.
!> @details
!> The caller's update is G += alpha * xcols * ycols^T. The coefficient is folded
!> into the X column here so the flush stays a plain X*Y^T.
!--------------------------------------------------------------------
   subroutine delay_append(nf, alpha, xcols, ycols, d, GR)
      implicit none
      integer, intent(in) :: nf, d
      Complex (Kind=Kind(0.d0)), intent(in)    :: alpha
      Complex (Kind=Kind(0.d0)), intent(in)    :: xcols(ndim_s, d), ycols(ndim_s, d)
      Complex (Kind=Kind(0.d0)), intent(inout) :: GR(:,:,:)
      Complex (Kind=Kind(0.d0)) :: one
      integer :: l, c
      c = ncol(nf)
      do l = 1, d
         call ZCOPY(ndim_s, xcols(1,l), 1, xp(1, c+l, nf), 1)
         call ZSCAL(ndim_s, alpha, xp(1, c+l, nf), 1)
         call ZCOPY(ndim_s, ycols(1,l), 1, yp(1, c+l, nf), 1)
      enddo
      ncol(nf) = c + d
      if (ncol(nf) >= kmax) call delay_flush(nf, GR)
      ! The shadow takes the same update immediately -- the arm being compared
      ! against, and the reason this mode is slower than not delaying at all.
      if (verify) then
         one = cmplx(1.d0, 0.d0, Kind(0.d0))
         call ZGEMM('N', 'T', ndim_s, ndim_s, d, alpha, xcols, ndim_s, &
            &       ycols, ndim_s, one, gshadow(1,1,nf), ndim_s)
      endif
   end subroutine delay_append

!--------------------------------------------------------------------
!> @brief
!> Conjugate the panels with a vertex operator, mirroring Op_Wrapup/Op_Wrapdo.
!> @details
!> A thin pass-through to Op_Wrap_panels, which lives in Operator_mod beside the
!> routines it mirrors so that an edit to one is visible from the other.
!--------------------------------------------------------------------
   subroutine delay_wrap(nf, Op, HS_Field, N_Type, nt, updo)
      implicit none
      integer, intent(in) :: nf, N_Type, nt
      Type (Operator), intent(in) :: Op
      Complex (Kind=Kind(0.d0)), intent(in) :: HS_Field
      character(len=1), intent(in) :: updo
      if (.not. active) return
      ! The shadow is a plain Green's function, so it takes the ordinary wrap --
      ! and unconditionally, since it must follow the real one whether or not the
      ! panels currently hold anything.
      if (verify) then
         if (updo == 'u' .or. updo == 'U') then
            call Op_Wrapup(gshadow(:,:,nf), Op, HS_Field, ndim_s, N_Type, nt)
         else
            call Op_Wrapdo(gshadow(:,:,nf), Op, HS_Field, ndim_s, N_Type, nt)
         endif
      endif
      if (ncol(nf) <= 0) return
      call Op_Wrap_panels(xp(1,1,nf), yp(1,1,nf), Op, HS_Field, ndim_s, &
         &                ncol(nf), N_Type, nt, updo)
   end subroutine delay_wrap

end module delayed_update_mod