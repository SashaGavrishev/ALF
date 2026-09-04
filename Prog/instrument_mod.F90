!  Copyright (C) 2016 - 2026 The ALF project
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

!--------------------------------------------------------------------
!> @brief
!> One switch for this fork's measurement instrumentation.
!>
!> @details
!> The timers and counters exist to measure F and F_hop for the delayed
!> update; they are provenance, not physics. ALF_INSTRUMENT gates all of
!> them, so a stock build writes nothing extra to info.
!>
!> Two levels, deliberately: the environment variable governs cost and
!> output, the ALF_INSTRUMENT *macro* governs bitwise identity. Only the
!> preprocessor can remove the near-tie hoist from the accept/reject line
!> in upgrade_mod, which a runtime test cannot -- see CONSOLIDATION.md 3.4.
!--------------------------------------------------------------------
Module Instrument_mod

  Implicit none

  private
  public :: instrument_on, instrument_env

  ! -1 until first read; 0/1 thereafter.
  Integer, private, save :: master = -1

Contains

!--------------------------------------------------------------------
!> @brief
!> Whether the instrumentation is enabled. Reads ALF_INSTRUMENT once.
!> Unset, empty or "0" is off, which is the default.
!--------------------------------------------------------------------
  Logical function instrument_on()
    Implicit none
    Character(len=32) :: text
    Integer           :: length, status, value, ios

    if (master < 0) then
       master = 0
       call get_environment_variable("ALF_INSTRUMENT", text, length, status)
       if (status == 0 .and. length > 0) then
          read(text(1:length), *, iostat=ios) value
          if (ios == 0 .and. value /= 0) master = 1
       endif
    endif
    instrument_on = master > 0

  end function instrument_on

!--------------------------------------------------------------------
!> @brief
!> Integer-valued refinement of the master switch, e.g. ALF_UPDATE_SAMPLE.
!>
!> @details
!> Returns default when the variable is unset or unparsable, so a typo
!> degrades to the documented behaviour rather than to zero. Callers cache
!> the result themselves; this does not, because each has its own default.
!>
!> @param[in] name     Environment variable to read.
!> @param[in] default  Value when unset or unparsable.
!> @param[in] minimum  Lower clamp on an otherwise valid value.
!--------------------------------------------------------------------
  Integer function instrument_env(name, default, minimum)
    Implicit none
    Character(len=*), Intent(In) :: name
    Integer,          Intent(In) :: default, minimum
    Character(len=32) :: text
    Integer           :: length, status, value, ios

    instrument_env = default
    call get_environment_variable(name, text, length, status)
    if (status == 0 .and. length > 0) then
       read(text(1:length), *, iostat=ios) value
       if (ios == 0) instrument_env = max(value, minimum)
    endif

  end function instrument_env

end Module Instrument_mod
