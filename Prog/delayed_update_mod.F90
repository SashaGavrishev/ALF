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
   public :: delay_wrap, delay_pending, delay_verify_on, delay_source_name
   public :: delay_log

   ! Panels and their live column count, one set per flavour. Allocated once
   ! beside Wrapgr_alloc rather than per slice: they are Ndim*(k+dmax) per
   ! flavour against Ndim**2 for one Green's function, so even at the depth
   ! ceiling they stay a fraction of what the matrix they correct costs.
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

   ! Bounds on the depth "auto" may resolve to. The ceiling is the deepest k
   ! delay_consistency holds to trajectory identity, so it moves only after that
   ! ladder does; see delay_depth.
   Integer, private, parameter :: K_FLOOR   = 8
   Integer, private, parameter :: K_CEILING = 256

   ! The resolved "auto" depth, cached because delay_depth is called more than
   ! once per run -- delay_alloc sets kmax from it and Wrapgr_delay_alloc reports
   ! it -- and the probe below is a timing, so a second call could answer
   ! differently and make Control report a depth kmax was never set from.
   Integer, private, save :: k_resolved = 0

   ! How that depth was arrived at, for the info file. A probe that quietly fell
   ! back to the formula on every chain is a probe that is not running, and
   ! reporting only the number would not show it.
   Character (Len=16), private, save :: k_source = 'off'

   ! Depths the probe times. Coarse deliberately: the cost curve is flat near its
   ! minimum, so neighbouring rungs differ by less than the run-to-run scatter on
   ! a shared node, and a fine ladder would cost more while resolving nothing.
   ! Confined to the validated range, since nothing outside it may be selected.
   Integer, private, parameter :: N_CAND = 6
   Integer, private, parameter :: K_CAND(N_CAND) = [8, 16, 32, 64, 128, 256]

   ! Each timed call is repeated until it clears this, so the clock's resolution
   ! is not what is being measured.
   Real (Kind=Kind(0.d0)), private, parameter :: PROBE_MIN_SECONDS = 5.d-3
   Integer,                private, parameter :: PROBE_MAX_REPS    = 4096

   ! Whole ladder measured this many times, keeping the least of each candidate.
   ! A packed node is the case this exists for and it is also the noisiest: a
   ! neighbour's burst inflates whichever candidate happened to run under it, and
   ! one sample cannot tell that from a real cost. Sweeping the ladder repeatedly
   ! rather than repeating each candidate in place keeps a slow patch from
   ! landing entirely on one rung.
   Integer, private, parameter :: PROBE_SWEEPS = 3

   ! Candidates within this of the best are not distinguishable from it, so the
   ! choice between them is made by the curve's shape instead of by noise: the
   ! basin is asymmetric -- undershooting k costs far more than overshooting it
   ! -- so the largest such candidate wins. This also stabilises the answer,
   ! since the band has to move a long way to change which rung is the largest
   ! inside it, where an argmin flips on any jitter at all.
   Real (Kind=Kind(0.d0)), private, parameter :: PROBE_MARGIN = 1.05d0
   Integer (Kind=8),       private, save      :: probe_c0 = 0

   ! Kept for delay_log: the curve the probe measured, what it cost to measure,
   ! and the request it was resolving. A depth on its own says what was chosen
   ! and not whether the choice was real -- a flat curve and a sharp minimum
   ! print the same number.
   Real (Kind=Kind(0.d0)), private, save :: probe_cost(N_CAND) = -1.d0
   Real (Kind=Kind(0.d0)), private, save :: probe_seconds = 0.d0
   Character (Len=32),     private, save :: k_request_text = '<unset>'
   Integer,                private, save :: k_ndim = 0

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
!> integer fixes the depth, and is used verbatim -- never clamped, which is what
!> lets the validation harnesses drive depths past the ceiling.
!>
!> "auto" *measures* the depth: delay_probe times the two k-dependent costs at
!> this Ndim and takes the argmin, falling back to delay_formula's closed form
!> when the measurement cannot be trusted. It is resolved once and cached in
!> k_resolved, because this function is called more than once per run -- delay_alloc
!> sets kmax from it and Wrapgr_delay_alloc reports it -- and a timing asked
!> twice can answer twice.
!>
!> Measuring rather than deriving is the point. The closed form assumes bandwidth
!> multiplies the panel term and the amortised flush alike and so cancels between
!> them, leaving an optimum in Ndim alone; it does not cancel, because the panels
!> are Ndim*k and stay cache-resident where the Green's function does not. How
!> far apart the two run is a property of the machine and of the library's
!> small-k ZGEMM, which is exactly what a formula cannot carry from one cluster
!> to another. (The ceiling was once argued instead from a compute-bound knee in
!> the flush at a multiple of the level-3/level-2 rate ratio. There is no such
!> knee: the flush's rate is still climbing across every k worth using.)
!>
!> A depth chosen by measurement varies between runs of one chain, which is only
!> safe because the delayed path consumes no random number the immediate one does
!> not and so replays the same Markov chain at any k -- verified bitwise on
!> confout across the whole ladder. Without that this would not be defensible.
!>
!> The clamp [8, 256] is a validated bound, not a guard: delay_consistency holds
!> every depth to 256 to trajectory identity with the Green's function flat in k,
!> and nothing may be selected past what that ladder covers. Raising it means
!> extending the ladder first.
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
            k_request_text = trim(adjustl(text(1:length)))
            if (trim(adjustl(text(1:length))) == "auto" .or. &
              & trim(adjustl(text(1:length))) == "AUTO") then
               k_request = K_AUTO
            else
               read (text(1:length), *, iostat=status) value
               if (status == 0 .and. value >= 0) then
                  k_request = value
               else
                  ! Unreadable, so the delay stays off -- and that is worth
                  ! saying, since a typo would otherwise silently cost the run
                  ! everything the delay was enabled for.
                  k_request_text = trim(k_request_text)//' (unreadable)'
               endif
            endif
         endif
      endif

      k_ndim = Ndim
      if (k_request == K_AUTO) then
         ! Once per run, then cached: this is a timing, and a second call could
         ! answer differently.
         if (k_resolved == 0) k_resolved = delay_probe(Ndim)
         delay_depth = k_resolved
      else
         delay_depth = k_request
         if (k_request > 0) k_source = 'fixed'
      endif
   end function delay_depth

!--------------------------------------------------------------------
!> @brief
!> How the depth in force was arrived at: off, fixed, probe or formula.
!--------------------------------------------------------------------
   function delay_source_name() result(name)
      implicit none
      Character (Len=16) :: name
      name = k_source
   end function delay_source_name

!--------------------------------------------------------------------
!> @brief
!> Say what the delay is set to and how that was decided.
!> @details
!> Called once at setup, from main under the rank guard -- this module is
!> deliberately free of MPI, so it cannot decide for itself whether to print and
!> does not try.
!>
!> The probe's whole curve is printed, not only its argmin, because the argmin
!> alone cannot be judged: a flat curve and a sharp minimum report the same
!> depth, and only the first means the choice did not matter. Printing it also
!> makes the fallback legible -- a run that says "formula" is a run where the
!> measurement was refused, which is a thing to notice rather than to infer from
!> a depth that happens to equal sqrt(2*Ndim).
!--------------------------------------------------------------------
   subroutine delay_log(unit)
      implicit none
      integer, intent(in) :: unit
      integer :: i
      Real (Kind=Kind(0.d0)) :: lo

      write (unit, '(a)') ' Delayed update:'
      write (unit, '(a,a)')      '   ALF_DELAY_K            : ', trim(k_request_text)
      if (kmax <= 0) then
         write (unit, '(a)')     '   status                 : off (immediate updates)'
         return
      endif
      write (unit, '(a,i0)')     '   Ndim                   : ', k_ndim
      write (unit, '(a,i0)')     '   depth k                : ', kmax
      write (unit, '(a,a)')      '   chosen by              : ', trim(k_source)
      write (unit, '(a,i0)')     '   panel width (k + dmax) : ', panel_w
      write (unit, '(a,i0,a,i0,a)') '   validated range        : [', &
        & K_FLOOR, ', ', K_CEILING, ']'

      if (trim(k_source) == 'formula') &
        & write (unit, '(a)') '   NB the probe was refused; this is the closed form'

      if (probe_cost(1) < 0.d0) return

      write (unit, '(a,f6.3,a)') '   probe cost             : ', probe_seconds, ' s'
      write (unit, '(a)')        '        k   rel. cost   (1.00 = best)'
      ! Masked reduction over an empty set returns +huge, which would then divide
      ! every row into nonsense rather than obviously failing. Only reachable if
      ! system_clock reported no rate at all, but the table is a diagnostic and a
      ! diagnostic that lies is worse than one that declines to answer.
      if (.not. any(probe_cost > 0.d0)) then
         write (unit, '(a)') '   (no timings: the clock reported no rate)'
         return
      endif
      lo = minval(probe_cost, mask=(probe_cost > 0.d0))
      do i = 1, N_CAND
         ! Labelled from k against Ndim, which is the actual reason a candidate
         ! was skipped -- not from its cost being unset, which is the same state
         ! for several different causes.
         if (K_CAND(i) > k_ndim) then
            write (unit, '(a,i5,a)') '   ', K_CAND(i), '        --   (above Ndim)'
         else if (probe_cost(i) <= 0.d0 .or. probe_cost(i) >= huge(1.d0)) then
            write (unit, '(a,i5,a)') '   ', K_CAND(i), '        --   (not timed)'
         else if (K_CAND(i) == kmax) then
            write (unit, '(a,i5,f12.3,a)') '   ', K_CAND(i), probe_cost(i)/lo, '   <- chosen'
         else
            write (unit, '(a,i5,f12.3)')   '   ', K_CAND(i), probe_cost(i)/lo
         endif
      enddo
   end subroutine delay_log

!--------------------------------------------------------------------
!> @brief
!> The closed-form depth: nint(sqrt(2*Ndim)), clamped.
!> @details
!> Where the panel cost k and the amortised flush 2*Ndim/k cross under a model
!> in which bandwidth multiplies both and so cancels. It does not cancel -- the
!> panels are Ndim*k and stay cache-resident where the Green's function does not
!> -- which is why this is the fallback and delay_probe is what "auto" runs.
!> Kept as the fallback rather than deleted: it needs no measurement and so
!> cannot fail, which is exactly what a fallback has to offer.
!>
!> Deliberately not rounded to a power of two: k is a flush threshold, not a
!> blocking factor, and no BLAS call here wants a particular inner dimension.
!--------------------------------------------------------------------
   integer function delay_formula(Ndim)
      implicit none
      integer, intent(in) :: Ndim
      integer :: k
      k = nint(sqrt(2.d0*real(Ndim, Kind(0.d0))))
      delay_formula = min(K_CEILING, max(K_FLOOR, k))
      ! Never wider than the matrix, which delay_probe refuses for its candidates
      ! and the fallback had no reason to allow: past Ndim the update is not low
      ! rank any more and the flush costs more than rebuilding G would. Only
      ! reachable below Ndim = K_FLOOR, where it also means less accumulation
      ! before a flush, so it cannot weaken the numerics the clamp protects.
      delay_formula = min(delay_formula, max(1, Ndim))
   end function delay_formula

!--------------------------------------------------------------------
!> @brief
!> Pick the depth by timing the two k-dependent costs at this Ndim.
!> @details
!> Per accepted flip the delayed scheme pays a flush ZGEMM('N','T',Ndim,Ndim,k)
!> once every k/d flips, and 2*d panel ZGEMVs against a panel that is half full
!> on average:
!>
!>     cost(k) = t_gemm(k)*d/k + 2*d*t_gemv(k/2)
!>             = d * [ t_gemm(k)/k + 2*t_gemv(k/2) ]
!>
!> **d factors out, so the argmin does not depend on the operator rank** -- nor
!> on the acceptance rate, which scales every accepted-flip cost alike. That is
!> what makes this cheap: no ZGERU baseline is needed either, since a speedup is
!> not being computed, only a minimum located. The O(d**2*k) ratio correction is
!> left out; it is a per-proposal cost of order one percent here and including it
!> would need the acceptance rate the probe deliberately avoids.
!>
!> Why measure at all: the closed form assumes the two terms share a bandwidth
!> and it cancels between them. The panels are Ndim*k and stay cache-resident
!> where the Green's function does not, so they run at different bandwidths, by a
!> ratio that is a property of the machine and of the library's small-k ZGEMM.
!> That is not something a formula can carry across a cluster.
!>
!> Cost is tens of milliseconds against a segment of hours. The scratch matrix is
!> the real price: one Ndim**2 array, transiently, on top of what ALF already
!> holds, and every rank of a packed node reaches this at the same moment.
!>
!> Falls back to delay_formula whenever the measurement cannot be trusted --
!> allocation refused, or a curve whose spread is small enough to be noise. The
!> source is recorded either way, because a probe silently falling back on every
!> chain is a probe that is not running.
!--------------------------------------------------------------------
   integer function delay_probe(Ndim)
      implicit none
      integer, intent(in) :: Ndim
      Complex (Kind=Kind(0.d0)), allocatable :: g(:,:), xs(:,:), ys(:,:)
      Complex (Kind=Kind(0.d0)), allocatable :: v(:), w(:)
      Real (Kind=Kind(0.d0)) :: cost(N_CAND), tg, tv, lo, hi, this
      integer :: i, k, c, kwide, stat, sweep, best
      integer (Kind=8) :: wall0, wall1, wall_rate

      k_source = 'formula'
      delay_probe = delay_formula(Ndim)

      ! No candidate may exceed Ndim: past that the update is no longer low rank
      ! and the flush costs more than rebuilding the matrix would.
      kwide = 0
      do i = 1, N_CAND
         if (K_CAND(i) <= Ndim) kwide = K_CAND(i)
      enddo
      if (kwide < K_FLOOR) return

      allocate (g(Ndim,Ndim), xs(Ndim,kwide), ys(Ndim,kwide), &
              & v(kwide), w(Ndim), stat=stat)
      if (stat /= 0) return

      call probe_fill(g, Ndim, Ndim)
      call probe_fill(xs, Ndim, kwide)
      call probe_fill(ys, Ndim, kwide)
      call probe_fill_vec(v, kwide)
      call probe_fill_vec(w, Ndim)

      cost = huge(1.d0)
      ! Its own clock, not probe_clock_start: the per-candidate timings below
      ! use that one, and a nested pair would leave this reading the last of
      ! them instead of the whole probe.
      call system_clock(wall0)
      do sweep = 1, PROBE_SWEEPS
         do i = 1, N_CAND
            k = K_CAND(i)
            if (k > kwide) cycle
            c = max(1, k/2)
            tg = time_flush(g, xs, ys, Ndim, k)
            tv = time_panel(xs, v, w, Ndim, c)
            this = tg/real(k, Kind(0.d0)) + 2.d0*tv
            ! Least, not mean: contention only ever adds time, so the smallest
            ! reading is the one least polluted by a neighbour, where a mean
            ! would carry every burst it happened to see.
            if (this < cost(i)) cost(i) = this
         enddo
      enddo
      call system_clock(wall1, wall_rate)
      if (wall_rate > 0) probe_seconds = &
        & real(wall1 - wall0, Kind(0.d0))/real(wall_rate, Kind(0.d0))
      probe_cost = cost

      deallocate (g, xs, ys, v, w)

      ! A curve flat across the *whole* ladder carries no information, so there is
      ! nothing to pick from and the formula at least answers the same way every
      ! time.
      lo = minval(cost)
      hi = maxval(cost, mask=(cost < huge(1.d0)))
      if (lo <= 0.d0 .or. hi < PROBE_MARGIN*lo) return

      ! Not minloc. The ambiguity is between neighbouring rungs near the minimum,
      ! which sit inside the run-to-run scatter; comparing the ends of the ladder
      ! never sees it. Take the largest candidate within PROBE_MARGIN of the best.
      best = K_CAND(1)
      do i = 1, N_CAND
         if (cost(i) >= huge(1.d0)) cycle
         if (cost(i) <= PROBE_MARGIN*lo .and. K_CAND(i) > best) best = K_CAND(i)
      enddo

      delay_probe = min(K_CEILING, max(K_FLOOR, best))
      k_source = 'probe'
   end function delay_probe

!--------------------------------------------------------------------
!> @brief
!> Entries of modulus ~1 with no dominant diagonal, for the probe's operands.
!> @details
!> Deterministic rather than random, and the requirement is stricter than it may
!> look: the probe runs *after* Set_Random_number_Generator (main.F90 seeds the
!> Monte Carlo stream, then calls Wrapgr_delay_alloc), so a draw taken here would
!> not merely perturb the disorder -- it would shift the whole Markov chain, and
!> by a different amount on every machine, since the number of draws would follow
!> the timing. Nothing here may touch the generator.
!--------------------------------------------------------------------
   subroutine probe_fill(a, m, n)
      implicit none
      integer, intent(in) :: m, n
      Complex (Kind=Kind(0.d0)), intent(out) :: a(m,n)
      integer :: i, j
      do j = 1, n
         do i = 1, m
            a(i,j) = cmplx(sin(real(i + 2*j, Kind(0.d0))), &
                         & cos(real(3*i - j, Kind(0.d0))), Kind(0.d0))
         enddo
      enddo
   end subroutine probe_fill

   subroutine probe_fill_vec(a, n)
      implicit none
      integer, intent(in) :: n
      Complex (Kind=Kind(0.d0)), intent(out) :: a(n)
      integer :: i
      do i = 1, n
         a(i) = cmplx(sin(real(i, Kind(0.d0))), cos(real(2*i, Kind(0.d0))), Kind(0.d0))
      enddo
   end subroutine probe_fill_vec

!--------------------------------------------------------------------
!> @brief
!> Seconds for one flush, ZGEMM('N','T',Ndim,Ndim,k), repeated to clear the clock.
!> @details
!> alpha is tiny so that thousands of accumulated updates cannot drift g towards
!> overflow or into denormals: this measures traffic, and arithmetic that changed
!> character partway through would not be the traffic ALF pays. Non-zero because
!> a BLAS may return immediately on alpha == 0.
!--------------------------------------------------------------------
   real (Kind=Kind(0.d0)) function time_flush(g, xs, ys, Ndim, k)
      implicit none
      integer, intent(in) :: Ndim, k
      Complex (Kind=Kind(0.d0)), intent(inout) :: g(Ndim,Ndim)
      Complex (Kind=Kind(0.d0)), intent(in)    :: xs(Ndim,*), ys(Ndim,*)
      Complex (Kind=Kind(0.d0)) :: alpha, one
      integer :: rep, reps
      alpha = cmplx(1.d-8, 0.d0, Kind(0.d0))
      one   = cmplx(1.d0, 0.d0, Kind(0.d0))
      reps = 1
      do
         call probe_clock_start()
         do rep = 1, reps
            call ZGEMM('N', 'T', Ndim, Ndim, k, alpha, xs, Ndim, ys, Ndim, one, g, Ndim)
         enddo
         time_flush = probe_clock_stop()
         if (time_flush >= PROBE_MIN_SECONDS .or. reps >= PROBE_MAX_REPS) exit
         reps = reps*4
      enddo
      time_flush = time_flush/real(reps, Kind(0.d0))
   end function time_flush

!--------------------------------------------------------------------
!> @brief
!> Seconds for one panel ZGEMV against c live columns.
!--------------------------------------------------------------------
   real (Kind=Kind(0.d0)) function time_panel(xs, v, w, Ndim, c)
      implicit none
      integer, intent(in) :: Ndim, c
      Complex (Kind=Kind(0.d0)), intent(in)    :: xs(Ndim,*)
      Complex (Kind=Kind(0.d0)), intent(in)    :: v(*)
      Complex (Kind=Kind(0.d0)), intent(inout) :: w(Ndim)
      Complex (Kind=Kind(0.d0)) :: alpha, one
      integer :: rep, reps
      alpha = cmplx(1.d-8, 0.d0, Kind(0.d0))
      one   = cmplx(1.d0, 0.d0, Kind(0.d0))
      reps = 1
      do
         call probe_clock_start()
         do rep = 1, reps
            call ZGEMV('N', Ndim, c, alpha, xs, Ndim, v, 1, one, w, 1)
         enddo
         time_panel = probe_clock_stop()
         if (time_panel >= PROBE_MIN_SECONDS .or. reps >= PROBE_MAX_REPS) exit
         reps = reps*4
      enddo
      time_panel = time_panel/real(reps, Kind(0.d0))
   end function time_panel

   subroutine probe_clock_start()
      implicit none
      call system_clock(probe_c0)
   end subroutine probe_clock_start

   real (Kind=Kind(0.d0)) function probe_clock_stop()
      implicit none
      integer (Kind=8) :: c1, rate
      call system_clock(c1, rate)
      if (rate <= 0) then
         probe_clock_stop = 0.d0
      else
         probe_clock_stop = real(c1 - probe_c0, Kind(0.d0))/real(rate, Kind(0.d0))
      endif
   end function probe_clock_stop

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

      ! Recorded even when the delay is off, because the GR dummies above are
      ! declared with them. delay_open and delay_close are called on every slice
      ! regardless, and a dummy shaped from a stale zero would be wrong before
      ! the early return ever ran.
      ndim_s = Ndim
      nfl_s  = N_FL

      kmax = delay_depth(Ndim)
      if (kmax <= 0) return

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
      ! Explicit shape, not assumed shape. These are handed element-first to
      ! ZGEMM and ZCOPY, which have no explicit interface, and sequence
      ! association from an assumed-shape actual is not something the standard
      ! guarantees -- a compiler may pass a descriptor or a copy. upgrade_mod
      ! declares the same array the same way for the same reason.
      Complex (Kind=Kind(0.d0)), intent(in) :: GR(ndim_s, ndim_s, nfl_s)
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
      ! Explicit shape, not assumed shape. These are handed element-first to
      ! ZGEMM and ZCOPY, which have no explicit interface, and sequence
      ! association from an assumed-shape actual is not something the standard
      ! guarantees -- a compiler may pass a descriptor or a copy. upgrade_mod
      ! declares the same array the same way for the same reason.
      Complex (Kind=Kind(0.d0)), intent(inout) :: GR(ndim_s, ndim_s, nfl_s)
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
      ! Explicit shape, not assumed shape. These are handed element-first to
      ! ZGEMM and ZCOPY, which have no explicit interface, and sequence
      ! association from an assumed-shape actual is not something the standard
      ! guarantees -- a compiler may pass a descriptor or a copy. upgrade_mod
      ! declares the same array the same way for the same reason.
      Complex (Kind=Kind(0.d0)), intent(inout) :: GR(ndim_s, ndim_s, nfl_s)
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
   subroutine delay_block(nf, GR, P, d, blk, ldb)
      use Control, only: Control_delay_split
      implicit none
      integer, intent(in) :: nf, d, P(d)
      ! Leading dimension of blk, taken rather than assumed equal to d. The
      ! caller's array is sized by the widest rank over calculated flavours,
      ! while d is this flavour's, and the two differ as soon as a Hamiltonian
      ! gives its flavours different vertex ranks. Declaring blk(d,d) then maps
      ! the columns onto a stride the caller does not read back with, silently,
      ! since sequence association raises no shape error.
      integer, intent(in) :: ldb
      ! Explicit shape, not assumed shape. These are handed element-first to
      ! ZGEMM and ZCOPY, which have no explicit interface, and sequence
      ! association from an assumed-shape actual is not something the standard
      ! guarantees -- a compiler may pass a descriptor or a copy. upgrade_mod
      ! declares the same array the same way for the same reason.
      Complex (Kind=Kind(0.d0)), intent(in)  :: GR(ndim_s, ndim_s, nfl_s)
      Complex (Kind=Kind(0.d0)), intent(out) :: blk(ldb,*)
      real (Kind=Kind(0.d0)) :: worst, split
      ! Only referenced under verify, which is a development mode; sized from the
      ! live column count so an unverified run allocates nothing meaningful.
      Complex (Kind=Kind(0.d0)) :: rowbuf(ndim_s), tmpc(max(ncol(nf),1))
      integer :: n, m, c, i
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
         ! The same elements built the way delay_row builds them -- one ZGEMV
         ! against the Y panel rather than the intrinsic sum above -- and the
         ! largest disagreement booked separately from the shadow comparison.
         !
         ! It is not a check on either path being right; both are compared to
         ! the shadow below and in delay_row. It measures how far they are from
         ! *each other*, which the immediate scheme keeps at exactly zero by
         ! taking both from one GR element. The acceptance determinant and the
         ! Woodbury denominator cancel against each other, so a scheme can be
         ! accurate against truth and still lose digits in that cancellation,
         ! and nothing else here would see it.
         if (c > 0) then
            split = 0.d0
            do n = 1, d
               do i = 1, ndim_s
                  rowbuf(i) = GR(P(n), i, nf)
               enddo
               tmpc(1:c) = xp(P(n), 1:c, nf)
               call ZGEMV('N', ndim_s, c, cmplx(1.d0, 0.d0, Kind(0.d0)), &
                    &     yp(1,1,nf), ndim_s, tmpc, 1, &
                    &     cmplx(1.d0, 0.d0, Kind(0.d0)), rowbuf, 1)
               do m = 1, d
                  split = max(split, abs(blk(n,m) - rowbuf(P(m))))
               enddo
            enddo
            call Control_delay_split(split/max(maxval(abs(gshadow(:,:,nf))), 1.d-300))
         endif
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
      ! Explicit shape, not assumed shape. These are handed element-first to
      ! ZGEMM and ZCOPY, which have no explicit interface, and sequence
      ! association from an assumed-shape actual is not something the standard
      ! guarantees -- a compiler may pass a descriptor or a copy. upgrade_mod
      ! declares the same array the same way for the same reason.
      Complex (Kind=Kind(0.d0)), intent(in)  :: GR(ndim_s, ndim_s, nfl_s)
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
      ! Explicit shape, not assumed shape. These are handed element-first to
      ! ZGEMM and ZCOPY, which have no explicit interface, and sequence
      ! association from an assumed-shape actual is not something the standard
      ! guarantees -- a compiler may pass a descriptor or a copy. upgrade_mod
      ! declares the same array the same way for the same reason.
      Complex (Kind=Kind(0.d0)), intent(in)  :: GR(ndim_s, ndim_s, nfl_s)
      Complex (Kind=Kind(0.d0)), intent(out) :: cols(ndim_s, d)
      Complex (Kind=Kind(0.d0)) :: one, tmp(max(ncol(nf),1))
      real (Kind=Kind(0.d0)) :: worst
      integer :: i, l, c
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
            ! `i`, not `c`: c holds the live column count and is read above.
            do i = 1, ndim_s
               worst = max(worst, abs(cols(i,l) - gshadow(i,P(l),nf)))
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
      ! Explicit shape, not assumed shape. These are handed element-first to
      ! ZGEMM and ZCOPY, which have no explicit interface, and sequence
      ! association from an assumed-shape actual is not something the standard
      ! guarantees -- a compiler may pass a descriptor or a copy. upgrade_mod
      ! declares the same array the same way for the same reason.
      Complex (Kind=Kind(0.d0)), intent(inout) :: GR(ndim_s, ndim_s, nfl_s)
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