!  Copyright (C) 2016 - 2022 The ALF project
!
!  This file is part of the ALF project.
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
!> @author
!> ALF-project
!
!> @brief
!> Write the equal-time Green's function, in full, at a sample of measurements.
!
!> @details
!> Observables are contractions of G, and a contraction can cancel an error that
!> is present in the matrix -- so "the observables agree" is weaker than "the
!> Green's function agrees". This writes G(i,j,nf) itself, every element, at the
!> exact points ham%Obser is handed it, so two runs of the same Markov chain can
!> be differenced element by element rather than through what they measured.
!>
!> Off unless ALF_GREEN_DUMP is set, and the value is a stride: 1 dumps every
!> measurement, n dumps every n-th. A stride rather than a flag because the
!> matrix is Ndim**2 complex per record -- 32 kB at Ndim = 32, 67 MB at
!> Ndim = 2048 -- and a full-rate dump of a production run would be larger than
!> the campaign. The counter is incremented on every call whether or not that
!> call writes, so the sample is a deterministic function of the trajectory and
!> two runs of one chain dump at the *same* measurements.
!>
!> Stream access and a fixed header, so the reader is numpy.fromfile and needs
!> no Fortran record markers:
!>
!>     header  : 3 x int32   -- ndim, nfl, format version
!>     record  : 1 x int32   -- ntau, the time slice
!>               ndim*ndim*nfl x complex128, Fortran order
!>
!> Diagnostic only. Nothing in ALF reads the file back.
!--------------------------------------------------------------------

module green_dump_mod
   use iso_fortran_env, only: error_unit
   implicit none

   private
   public :: green_dump, green_dump_close, green_dump_stride

   ! 32-bit by selected_int_kind rather than by kind=4, so the on-disk width the
   ! reader assumes is the one the standard guarantees.
   integer, parameter, private :: i4 = selected_int_kind(9)
   integer(kind=i4), parameter, private :: FORMAT_VERSION = 1_i4

   character(len=*), parameter, private :: DUMP_FILE = "green_dump.bin"

   ! -1 is "not yet read", 0 is off. Following ALF_DELAY_K and ALF_UPDATE_SAMPLE,
   ! which parse their environment once and cache it.
   integer, private, save :: stride = -1
   integer(Kind=Kind(0.d0)), private, save :: calls = 0
   integer, private, save :: unit_no = 0
   ! Whether the unit is connected. A separate flag, not the sign of unit_no:
   ! newunit= hands back a *negative* unit number by construction, so testing
   ! unit_no < 0 reads an open file as a closed one and reopens it on every
   ! record. That fails with "file already connected", and the failure path here
   ! disables dumping -- which produced a run with exactly one record and no
   ! other complaint.
   logical, private, save :: is_open = .false.

contains

!--------------------------------------------------------------------
!> @brief
!> The dump stride: 0 when ALF_GREEN_DUMP is unset, absent or not a positive
!> integer. Read once and cached.
!--------------------------------------------------------------------
   integer function green_dump_stride()
      implicit none
      character(len=32) :: text
      integer :: length, status, value

      if (stride < 0) then
         stride = 0
         call get_environment_variable("ALF_GREEN_DUMP", text, length, status)
         if (status == 0 .and. length > 0) then
            read (text(1:length), *, iostat=status) value
            if (status == 0 .and. value > 0) stride = value
         endif
      endif
      green_dump_stride = stride
   end function green_dump_stride

!--------------------------------------------------------------------
!> @brief
!> Write GR in full if this call falls on the stride.
!> @details
!> GR is assumed-shape so the module needs no dimensions of its own and links
!> against nothing in ALF -- the caller has whichever of GR or GR_Tilde it is
!> about to measure, and that is the matrix that must be recorded.
!--------------------------------------------------------------------
   subroutine green_dump(GR, ntau)
      implicit none
      complex(Kind=Kind(0.d0)), intent(in) :: GR(:,:,:)
      integer, intent(in) :: ntau

      integer :: status

      if (green_dump_stride() <= 0) return

      calls = calls + 1
      if (mod(calls, int(stride, Kind(0.d0))) /= 0) return

      ! The header carries one dimension and the reader squares it, so a
      ! non-square GR would describe a record length the file does not have and
      ! the reader would misparse it into wrong-shaped records rather than
      ! complain. Nothing in ALF hands this a non-square Green's function;
      ! refusing is what keeps that an assumption that cannot rot quietly.
      if (size(GR, 1) /= size(GR, 2)) then
         write (error_unit, *) "green_dump: GR is ", size(GR, 1), "x", size(GR, 2), &
              & "; the dump format assumes square. Dumping disabled."
         stride = 0
         return
      endif

      if (.not. is_open) then
         open (newunit=unit_no, file=DUMP_FILE, form="unformatted", &
              & access="stream", status="replace", action="write", iostat=status)
         if (status /= 0) then
            write (error_unit, *) "green_dump: cannot open ", DUMP_FILE, &
                 & " (iostat ", status, "); dumping disabled"
            stride = 0
            return
         endif
         is_open = .true.
         write (unit_no) int(size(GR, 1), i4), int(size(GR, 3), i4), FORMAT_VERSION
      endif

      write (unit_no) int(ntau, i4)
      write (unit_no) GR
   end subroutine green_dump

!--------------------------------------------------------------------
!> @brief
!> Close the dump. Normal termination would close it anyway; this makes the
!> file complete at a point the caller controls.
!--------------------------------------------------------------------
   subroutine green_dump_close()
      implicit none
      if (is_open) then
         close (unit_no)
         is_open = .false.
      endif
   end subroutine green_dump_close

end module green_dump_mod
