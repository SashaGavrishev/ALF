#!/bin/sh
# shellcheck disable=SC2059
# This script sets necessary environment variables for compiling ALF.
# You need to source it prior to executing make.
USAGE="usage 'source configure.sh MACHINE MODE STAB'

Please choose one of the following MACHINEs:
 * GNU
 * Cedar
 * Intel
 * IntelLLVM or IntelX
 * PGI
 * SuperMUC-NG
 * JUWELS
 * FRITZ
 * PKS
 * PKS_ZEN
 * PKS_ZEN_MKL
   (all three accept ALF_ONEAPI_SETVARS=/path/to/setvars.sh or
    ALF_INTEL_MODULES='mod1 mod2 ...' to override the Intel toolchain)
 * PKS_AOCC
 * PKS_GNU_ZEN
 * RAVEN
Possible MODEs are:
 * MPI (default)
 * noMPI
 * Tempering
 * PARALLEL_PARAMS (shorthand PP)
Possible STABs are:
 * <no-argument> (default)
 * STAB1 (old)
 * STAB2 (old)
 * STAB3 (newest)
 * LOG (increases accessible scales, e.g. in beta or interaction strength by solving NaN issues)
Further optional arguments: 
  Devel: Compile with additional flags for development and debugging
  HDF5: Compile with HDF5
  NO-INTERACTIVE: Do not ask for user confirmation during execution of this script
  NO-FALLBACK: Do not use a fallback option in case of an unknown/no machine,
               but instead return with value 1
To hand an additional flag to the compiler, export it in the variable ALF_FLAGS_EXT prior to sourcing this script.

ALF usually self-compiles HDF5 and stores the library in subdirectories of ALF/HDF5.
This behavior can be changed by setting the environment variable ALF_HDF5_DIR.

For more details check the documentation.\n"

STABCONFIGURATION=""

export ALF_DIR="$PWD"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Create temporary directory for various checks with temporary files to be run in parallel
tmpdir=$(mktemp -d 2>/dev/null || mktemp -d -t 'tmpdir')
printf "\n${GREEN}Temporary directory %s created${NC}\n" "$tmpdir"

set_hdf5_flags()
{
  CC="$1" FC="$2" CXX="$3"
  
  $FC -o "$tmpdir/get_compiler_version.out" get_compiler_version.F90
  # This becomes a directory name, so strip # and / as well as whitespace and
  # punctuation: AOCC reports "AOCC_5.2.0-Build#2035", and a # in a build path
  # is treated as a comment by make and mishandled by libtool.
  compiler_vers=$("$tmpdir/get_compiler_version.out" | sed 's|[ ,()#/]|_|g')
  
  H5_major=1
  H5_minor=14
  H5_patch=6
  H5_suff=""
  if [ -n "${ALF_HDF5_DIR+x}" ]; then
    printf "\nUsing custom HDF5 directory '%s'\n" "${ALF_HDF5_DIR}"
    HDF5_DIR="${ALF_HDF5_DIR}/${compiler_vers}"
  else
    HDF5_DIR="$ALF_DIR/HDF5/${compiler_vers}"
  fi
  if [ ! -d "$HDF5_DIR" ]; then
    printf "\nHDF5 is not yet installed for compiler '%s'.\n" "$compiler_vers"
    printf "ALF does never use global HDF5 libraries, but installs it locally in subfolders of '%s/HDF5'.\n" "$ALF_DIR"
    if [ "$NO_INTERACTIVE" = "" ]; then
      printf "Do you want download and install it now locally in the ALF folder? (Y/n):"
      read -r yn
    else
      yn="Y"
    fi
    case "$yn" in
      y|Y|"")
        printf "${GREEN}Downloading and installing HDF5 in %s.${NC}\n" "$HDF5_DIR"
        CC="$CC" FC="$FC" CXX="$CXX" HDF5_DIR="$HDF5_DIR" "$ALF_DIR/HDF5/install_hdf5.sh" ${H5_major} ${H5_minor} ${H5_patch} "${H5_suff}" || return 1
      ;;
      *) 
        printf "Skipping installation of HDF5.\n"
        rm -r "$tmpdir"
        printf "\n${GREEN}Temporary directory %s deleted${NC}\n" "$tmpdir"
        return 1
      ;;
    esac
  fi
  # A half-finished install leaves the directory in place, so the check above
  # skips reinstalling it on every later run while the Fortran module is still
  # missing. The compiler then falls through to a system hdf5.mod built by
  # another compiler and reports it as corrupt, far from the real cause.
  if [ ! -f "$HDF5_DIR/include/hdf5.mod" ] && [ ! -f "$HDF5_DIR/include/HDF5.mod" ]; then
    printf "${RED}\n==== Error: no hdf5.mod in %s/include ====${NC}\n" "$HDF5_DIR" 1>&2
    printf "${RED}The HDF5 install for this compiler is incomplete. Delete${NC}\n" 1>&2
    printf "${RED}%s and re-run to rebuild it.${NC}\n\n" "$HDF5_DIR" 1>&2
    return 1
  fi
  INC_HDF5="-I$HDF5_DIR/include"
  LIB_HDF5="-L$HDF5_DIR/lib $HDF5_DIR/lib/libhdf5hl_fortran.a $HDF5_DIR/lib/libhdf5_hl.a"

  h5_config="$("$HDF5_DIR"/bin/h5fc -showconfig 2>/dev/null)"
  EXTRA_LIBRARIES="$(printf '%s\n' "$h5_config" | grep 'Extra libraries:' | cut -f2 -d':')"

  # Whether libhdf5.a needs zlib is asked of the archive, not of h5fc: some
  # installs leave "Extra libraries:" empty and others have no usable h5fc at
  # all, but an undefined inflateInit_ in the archive is unambiguous. Without
  # this the link fails on compress2/inflate from H5Zdeflate.o. The config text
  # is kept as a fallback for platforms with no nm.
  if nm -u "$HDF5_DIR/lib/libhdf5.a" 2>/dev/null | grep -q 'inflateInit_' \
     || printf '%s\n' "$h5_config" | grep -q "deflate(zlib)"; then
    case " $EXTRA_LIBRARIES " in
      *" -lz "*) ;;
      *) EXTRA_LIBRARIES="$EXTRA_LIBRARIES -lz" ;;
    esac
  else
    printf "${RED}Warning: HDF5 installed without compression capabilies. The output files will not be compressed!${NC}\n" 1>&2
  fi
  for h5_lib in -ldl -lm; do
    case " $EXTRA_LIBRARIES " in
      *" $h5_lib "*) ;;
      *) EXTRA_LIBRARIES="$EXTRA_LIBRARIES $h5_lib" ;;
    esac
  done

  LIB_HDF5="$LIB_HDF5 $HDF5_DIR/lib/libhdf5_fortran.a $HDF5_DIR/lib/libhdf5.a $EXTRA_LIBRARIES -Wl,-rpath -Wl,$HDF5_DIR/lib"
}

check_libs()
{
    FC="$1" LIBS="$2"
    FC0="$(echo "$FC" | cut -f1 -d' ')"
    if command -v "$FC0" > /dev/null; then       # Compiler binary found
        if sh -c "$FC check_libs.f90 $LIBS -o $tmpdir/check_libs.out"; then  # Compiling with $LIBS is successful
            "$tmpdir/check_libs.out" || (
              printf "${RED}\n==== Error: Execution of test program using compiler <%s> ====${NC}\n" "$FC" 1>&2
              printf "${RED}==== and linear algebra libraries <%s> not successful. ====${NC}\n\n" "$LIBS" 1>&2
              # script gets terminated, so remove tmpdir
              rm -r "$tmpdir"
              printf "\n${GREEN}Temporary directory %s deleted${NC}\n" "$tmpdir"
              return 1
              )
        else
            printf "${RED}\n==== Error: Linear algebra libraries <%s> not found. ====${NC}\n\n" "$LIBS" 1>&2
              # script gets terminated, so remove tmpdir
              rm -r "$tmpdir"
              printf "\n${GREEN}Temporary directory %s deleted${NC}\n" "$tmpdir"
            return 1
        fi
    else
        printf "${RED}\n==== Error: Compiler <%s> not found. ====${NC}\n\n" "$FC" 1>&2
        # script gets terminated, so remove tmpdir
        rm -r "$tmpdir"
        printf "\n${GREEN}Temporary directory %s deleted${NC}\n" "$tmpdir"
        return 1
    fi
}

check_python()
{
    if ! command -v python3 > /dev/null; then
        printf "${RED}\n==== Error: Python 3 not found. =====${NC}\n\n" 1>&2
        return 1
    fi
}

find_mkl_flag()
{
  if command -v ifort > /dev/null; then
    ifort_major=$(ifort --version | head -n 1 | awk '{print $(NF - 1)}' | cut -d '.' -f 1)
    ifort_minor=$(ifort --version | head -n 1 | awk '{print $(NF - 1)}' | cut -d '.' -f 2)
    if [ "$ifort_major" -gt 2021 ] || { [ "$ifort_major" -eq 2021 ] && [ "$ifort_minor" -gt 3 ]; }; then
      INTELMKL="-qmkl"
    else
      INTELMKL="-mkl"
    fi
  elif command -v ifx > /dev/null; then
    INTELMKL="-qmkl"
  else 
    printf "${RED}\n==== Error: MKL only supported for ifort compiler. ====${NC}\n\n" "$FC" 1>&2
  fi
}

# Set BEST_MARCH to the first -march target in $2.. that compiler $1 accepts,
# by test-compiling. Availability is a toolchain property, not a hardware one:
# oneAPI added znver5 in 2025.2, gcc in 14.1. Pass a certainly-supported
# target last.
best_march()
{
  bm_fc="$1"
  shift
  printf 'program p\nend program p\n' > "$tmpdir/march_probe.f90"
  for bm_arch in "$@"; do
    if sh -c "$bm_fc -march=$bm_arch -c $tmpdir/march_probe.f90 -o $tmpdir/march_probe.o" \
         > /dev/null 2>&1; then
      BEST_MARCH="-march=$bm_arch"
      printf "\nTargeting %s\n" "$bm_arch"
      return 0
    fi
  done
  BEST_MARCH=""
  printf "${RED}Warning: <%s> accepts none of '%s'; building with no -march${NC}\n" "$bm_fc" "$*" 1>&2
  return 1
}

# Set NAN_GUARD_FLAG to the first flag in $3.. that makes compiler $1 keep a NaN
# self-comparison under optimisation flags $2, or "" if it already keeps one.
#
# Prog/control_mod.F90 guards each stabilisation with `if (any(A /= A))`. Any
# flag implying -ffinite-math-only lets the compiler assume no operand is NaN,
# fold that to .false. and delete the guard, with no diagnostic: a run whose
# Green function diverges then writes plausible-looking bins instead of
# aborting. ifx -fp-model=fast=2 does exactly this (measured; see
# scripts/benchmarks/nanguard.f90 in the parent repository), and
# Control_Precision_tau has no magnitude threshold to fall back on.
#
# Probed rather than hard-coded: the restoring flag differs between compilers
# and versions, and passing an unsupported one is a hard error on ifx. The probe
# is compiled without -march so it runs on the build node whatever the target
# is, and it is *executed* -- a compiler accepting the flag does not prove the
# flag changed the generated comparison. -static is dropped too: neither it nor
# the target affects whether the comparison is folded, but a fully static link
# can fail for its own reasons and would look like "no flag works".
# ALF_NAN_GUARD_FLAG overrides the probe.
set_nan_guard_flag()
{
  ng_fc="$1"
  ng_base=$(printf '%s' "$2" | sed 's/-march=[^ ]*//g; s/-xHost//g; s/-static[a-z-]*//g')
  shift 2
  if [ -n "${ALF_NAN_GUARD_FLAG+x}" ]; then
    NAN_GUARD_FLAG="${ALF_NAN_GUARD_FLAG}"
    printf "\nNaN guard flag pinned to '%s'\n" "${NAN_GUARD_FLAG}"
    return 0
  fi
  cat > "$tmpdir/nan_probe.f90" <<'EOF'
program nan_probe
  implicit none
  real(kind(0.d0)) :: a(2), z
  ! Runtime-valued, so the NaN is not constant-folded at compile time.
  z = real(command_argument_count(), kind(0.d0))
  a(1) = 1.d0
  a(2) = z/z
  if (any(a /= a)) then
     print *, "FIRED"
  else
     print *, "SILENT"
  end if
end program nan_probe
EOF
  for ng_flag in "" "$@"; do
    if sh -c "$ng_fc $ng_base $ng_flag -o $tmpdir/nan_probe.out $tmpdir/nan_probe.f90" \
         > /dev/null 2>&1 \
       && "$tmpdir/nan_probe.out" 2>/dev/null | grep -q FIRED; then
      NAN_GUARD_FLAG="$ng_flag"
      if [ -n "$ng_flag" ]; then
        printf "\nNaN guard needs %s at these optimisation settings; adding it\n" "$ng_flag"
      fi
      return 0
    fi
  done
  NAN_GUARD_FLAG=""
  printf "${RED}Warning: none of '%s' restores the NaN guard for <%s>.${NC}\n" "$*" "$ng_fc" 1>&2
  printf "${RED}  control_mod.F90 cannot detect a diverged Green function in this build.${NC}\n" 1>&2
  return 1
}

# AOCL (AMD BLIS + libFLAME) in place of MKL's BLAS/LAPACK. Sets
# AOCL_BLAS_LAPACK. libFLAME comes first: it provides LAPACK and calls into
# BLIS for BLAS.
# $1 is AOCL's Fortran runtime: -lgfortran (the default) for the -gcc flavour,
# "" for -aocc, whose runtime the flang driver links itself.
# Load the single-threaded (ST) flavour; the MT build adds a second OpenMP
# runtime alongside the compiler's.
# ALF_AOCL_LIB overrides the link line entirely.
set_aocl_flags()
{
  if [ "$#" -ge 1 ]; then
    aocl_fortran_rt="$1"
  else
    aocl_fortran_rt="-lgfortran"
  fi
  if [ -n "${ALF_AOCL_LIB:-}" ]; then
    AOCL_BLAS_LAPACK="$ALF_AOCL_LIB"
    return 0
  fi
  AOCL_BLAS_LAPACK="-lflame -lblis $aocl_fortran_rt"
  for aocl_root in "${AOCL_ROOT:-}" "${AOCL_DIR:-}" "${AOCL_HOME:-}"; do
    if [ -n "$aocl_root" ] && [ -d "$aocl_root/lib" ]; then
      # libblis pulls in libaoclutils. Naming it here makes it a direct
      # dependency of the binary, which the rpath below does cover.
      if ls "$aocl_root"/lib/libaoclutils.* > /dev/null 2>&1; then
        AOCL_BLAS_LAPACK="$AOCL_BLAS_LAPACK -laoclutils"
      fi
      # -rpath as well as -L: build and run are separate jobs, and the binary
      # must resolve libblis without the module being reloaded.
      # --disable-new-dtags emits DT_RPATH rather than DT_RUNPATH. Only DT_RPATH
      # is searched when resolving a *dependency's* dependencies, and without it
      # the loader ignores this path for anything libblis itself needs, failing
      # with "libaoclutils.so: cannot open shared object file" at run time on a
      # binary that linked cleanly. It applies to the whole link, not just this
      # -L: every rpath on the line becomes DT_RPATH, including HDF5's, and
      # DT_RPATH outranks LD_LIBRARY_PATH -- so no library in the resulting
      # binary can be swapped at run time by setting that variable.
      AOCL_BLAS_LAPACK="-L$aocl_root/lib -Wl,--disable-new-dtags -Wl,-rpath,$aocl_root/lib $AOCL_BLAS_LAPACK"
      return 0
    fi
  done
  printf "${RED}Warning: no AOCL root found in AOCL_ROOT/AOCL_DIR/AOCL_HOME;${NC}\n" 1>&2
  printf "${RED}  relying on the module's own search paths for %s${NC}\n" "$AOCL_BLAS_LAPACK" 1>&2
}

# Put an Intel toolchain on PATH for the PKS machine cases, and report which one.
# Three ways, in precedence order, so a newer compiler installed on the cluster
# can be used before the module system defaults to it:
#
#   ALF_ONEAPI_SETVARS=/path/to/oneapi/setvars.sh   source an install directly
#   ALF_INTEL_MODULES="intel/compiler/2026.0 ..."   load these modules instead
#   (neither)                                       the cluster's usual defaults
#
# Reports the resolved ifx version either way: which compiler you got decides
# which -march targets exist (best_march), and that is worth seeing rather than
# inferring from a build failure.
load_intel_env()
{
  if [ -n "${ALF_ONEAPI_SETVARS:-}" ]; then
    if [ ! -r "${ALF_ONEAPI_SETVARS}" ]; then
      printf "${RED}\n==== Error: ALF_ONEAPI_SETVARS=%s is not readable ====${NC}\n\n" \
        "${ALF_ONEAPI_SETVARS}" 1>&2
      return 1
    fi
    printf "\nSourcing oneAPI from %s\n" "${ALF_ONEAPI_SETVARS}"
    # --force: setvars refuses to re-run if a oneAPI is already in the
    # environment, which is exactly the case being overridden here.
    . "${ALF_ONEAPI_SETVARS}" --force > /dev/null 2>&1
  elif [ -n "${ALF_INTEL_MODULES:-}" ]; then
    printf "\nLoading Intel modules: %s\n" "${ALF_INTEL_MODULES}"
    for intel_mod in ${ALF_INTEL_MODULES}; do
      module load "$intel_mod" || return 1
    done
  else
    module load intel/umf
    module load intel/compiler-rt
    module load intel/tbb
    # Thread Composability Manager, a runtime dependency of the newer compilers
    # alongside tbb/umf/compiler-rt.
    module load intel/tcm
    module load intel/compiler
    module load intel/mkl
    module load intel/mpi
  fi
  if command -v ifx > /dev/null; then
    printf "Using %s\n" "$(ifx --version 2>&1 | head -n 1)"
  else
    printf "${RED}Warning: no ifx on PATH after loading the Intel toolchain${NC}\n" 1>&2
  fi
}

# gfortran's major version, or 0 if there is no gfortran. -dumpversion prints a
# bare major on some builds and a full "12.2.0" on others, and feeding the
# latter to `test -gt` fails with "integer expression expected".
gfortran_major()
{
  gfortran -dumpversion 2>/dev/null | cut -d. -f1 | grep -E '^[0-9]+$' || echo 0
}

set_intelcc()
{
  if command -v icx > /dev/null; then
    INTELCC="icx"
  elif command -v icc > /dev/null; then
    INTELCC="icc"
  elif command -v gcc > /dev/null; then
    INTELCC="gcc"
  else
    printf "${RED}\n==== Error: C compiler needed for HDF5. None of 'icx', 'icc', 'gcc' found ====${NC}\n\n" 1>&2
  fi
}

set_intelcxx()
{
  if command -v icpx > /dev/null; then
    INTELCXX="icpx"
  elif command -v icpc > /dev/null; then
    INTELCXX="icpc"
  elif command -v g++ > /dev/null; then
    INTELCXX="g++"
  else
    printf "${RED}\n==== Error: C++ compiler needed for HDF5. None of 'icpx', 'icpc', 'g++' found ====${NC}\n\n" 1>&2
  fi
}

# default optimization flags for Intel compiler
INTELOPTFLAGS="-cpp -O3 -fp-model fast=2 -xHost -unroll -finline-functions -ipo -ip -heap-arrays 1024 -no-wrap-margin -diag-disable=5268,10448,5462"
INTELOPTFLAGS="${INTELOPTFLAGS} -parallel -qopenmp"
INTELDEVFLAGS="-warn all -check all -g -traceback"
INTELUSEFULFLAGS="-std08"

INTELLLVMOPTFLAGS="-cpp -O3 -fp-model=fast=2 -no-prec-div -static -xHost -unroll -finline-functions -no-wrap-margin -diag-disable=5268,10448,5462"
# uncomment the next line if you want to use additional openmp parallelization
# INTELLLVMOPTFLAGS="${INTELLLVMOPTFLAGS} -qopenmp"
INTELLLVMDEVFLAGS="-warn all -check all,nouninit -g -traceback"
INTELLLVMUSEFULFLAGS="-std08"


# default optimization flags for AMD AOCC (classic flang: flang1/flang2, not
# LLVM Flang; implements the Fortran 2008 submodules ALF needs). Intel's
# -fp-model, -no-prec-div and -diag-disable spellings are rejected, so this is
# not a transliteration of the Intel set.
# -fno-finite-math-only: -ffast-math otherwise folds away Control_PrecisionG's
# `any(A /= A)` NaN test (Prog/control_mod.F90).
AOCCOPTFLAGS="-cpp -O3 -ffast-math -fno-finite-math-only -funroll-loops -finline-functions"
AOCCDEVFLAGS="-g -Wall"
# flang has no -std08 equivalent.
AOCCUSEFULFLAGS=""
# Serial driver; an MPI build would need the mpif90 wrapper.
AOCCCOMPILER="flang"

# default optimization flags for GNU compiler
GNUOPTFLAGS="-cpp -O3 -ffree-line-length-none -ffast-math"
GNUOPTFLAGS="${GNUOPTFLAGS} -fopenmp"
GNUDEVFLAGS="-Wconversion -Werror -Wno-error=cpp -fcheck=all -g -fbacktrace -fmax-errors=10 -O0 -ggdb"
GNUUSEFULFLAGS="-std=f2008"

# default optimization flags for PGI compiler
PGIOPTFLAGS="-Mpreprocess -O3 -Mfprelaxed -fast"
# uncomment the next line if you want to use additional openmp parallelization
PGIOPTFLAGS="${PGIOPTFLAGS} -mp"
PGIDEVFLAGS="-Minform=inform -C -g -traceback"
PGIUSEFULFLAGS=""

MACHINE=""
Machinev=0
MODE=""
modev=0
STAB=""
stabv=0
HDF5_ENABLED=""
NO_INTERACTIVE=""
NO_FALLBACK=""

while [ "$#" -gt "0" ]; do
  ARG="$(echo "$1" | tr '[:lower:]' '[:upper:]')"
  shift 1
  case "$ARG" in
    STAB1|STAB2|STAB3|LOG)
      if [ "$stabv" = "1" ]; then
         printf "Additional STAB configuration found. Overwriting %s with %s .\n" "$STAB" "$ARG" 1>&2
      fi
      STAB="$ARG"
      stabv="1"
    ;;
    NOMPI|MPI|TEMPERING|SERIAL|PARALLEL_PARAMS|PP)
      if [ "$modev" = "1" ]; then
         printf "Additional MODE configuration found. Overwriting %s with %s .\n" "$MODE" "$ARG" 1>&2
      fi
      MODE="$ARG"
      modev="1"
    ;;
    HDF5)
      HDF5_ENABLED="1"
    ;;
    DEVEL|DEVELOPMENT)
      GNUOPTFLAGS="$GNUOPTFLAGS $GNUDEVFLAGS"
      INTELOPTFLAGS="$INTELOPTFLAGS $INTELDEVFLAGS"
      INTELLLVMOPTFLAGS="$INTELLLVMOPTFLAGS $INTELLLVMDEVFLAGS"
      PGIOPTFLAGS="$PGIOPTFLAGS $PGIDEVFLAGS"
    ;;
    NO-INTERACTIVE)
      NO_INTERACTIVE="1"
    ;;
    NO-FALLBACK)
      NO_FALLBACK="1"
    ;;
    *)
      if [ "$Machinev" = "1" ]; then
         printf "Additional MACHINE / unrecognized configuration found. Overwriting %s with %s .\n" "$MACHINE" "$ARG" 1>&2
      fi
      MACHINE="$ARG"
      Machinev="1"
    ;;
  esac
done

printf "\n"

case $MODE in
  NOMPI|SERIAL)
    printf "serial job.\n"
    PROGRAMMCONFIGURATION=""
    INTELCOMPILER="ifort"
    INTELLLVMCOMPILER="ifx"
    GNUCOMPILER="gfortran"
    MPICOMP=0
  ;;

  TEMPERING)
    printf "Activating parallel tempering.\n"
    printf "This requires also MPI parallization which is set as well.\n"
    PROGRAMMCONFIGURATION="-DMPI -DTEMPERING"
    INTELCOMPILER="mpiifort"
    if command -v mpiifx > /dev/null; then
       INTELLLVMCOMPILER="mpiifx"
    else
       INTELLLVMCOMPILER="mpiifort -fc=ifx"
    fi
    GNUCOMPILER="mpifort"
    MPICOMP=1
  ;;

  MPI)
    printf "Activating MPI parallization.\n"
    PROGRAMMCONFIGURATION="-DMPI"
    INTELCOMPILER="mpiifort"
    if command -v mpiifx > /dev/null; then
       INTELLLVMCOMPILER="mpiifx"
    else
       INTELLLVMCOMPILER="mpiifort -fc=ifx"
    fi
    GNUCOMPILER="mpifort"
    MPICOMP=1
  ;;
 
  PARALLEL_PARAMS|PP)
    printf "Activating parallel runs with different parameters.\n"
    printf "This requires also MPI parallization which is set as well.\n"
    PROGRAMMCONFIGURATION="-DMPI -DTEMPERING -DPARALLEL_PARAMS"
    INTELCOMPILER="mpiifort"
    if command -v mpiifx > /dev/null; then
       INTELLLVMCOMPILER="mpiifx"
    else
       INTELLLVMCOMPILER="mpiifort -fc=ifx"
    fi
    GNUCOMPILER="mpifort"
    MPICOMP=1
  ;;

  *)
    printf "Activating ${RED}MPI parallization (default)${NC}.\n"
    printf "To turn MPI off, pass noMPI as the second argument.\n"
    printf "To turn on parallel tempering, pass Tempering as the second argument.\n"
    PROGRAMMCONFIGURATION="-DMPI"
    INTELCOMPILER="mpiifort"
    INTELLLVMCOMPILER="mpiifort -fc=ifx"
    GNUCOMPILER="mpifort"
    MPICOMP=1
  ;;
esac

printf "\n"

case $STAB in
  STAB1)
    STABCONFIGURATION="${STABCONFIGURATION} -DSTAB1"
    printf "Using older stabilization with UDV decompositions\n"
  ;;

  STAB2)
    STABCONFIGURATION="${STABCONFIGURATION} -DSTAB2"
    printf "Using older stabilization with UDV decompositions and additional normalizations\n"
  ;;

  STAB3)
    STABCONFIGURATION="${STABCONFIGURATION} -DSTAB3"
    printf "Using newest stabilization which separates large and small scales\n"
  ;;

  LOG)
    STABCONFIGURATION="${STABCONFIGURATION} -DSTABLOG"
    printf "Using log storage for internal scales\n"
  ;;

  *)
    printf "Using ${RED}default stabilization${NC}\n"
    printf "Possible alternative options are STAB1, STAB2, STAB3 and LOG\n"
  ;;
esac

case $MACHINE in
  #GNU (as Hybrid code)
  GNU)
    # -fallow-argument-mismatch was required by gfortran10 and MPICH, they changed default behaviour in v10
    test "$(gfortran_major)" -gt 9 && GNUOPTFLAGS="${GNUOPTFLAGS} -fallow-argument-mismatch"
    ALF_FC="$GNUCOMPILER"
    F90OPTFLAGS="$GNUOPTFLAGS"
    # GNUOPTFLAGS carries -ffast-math, which deletes control_mod.F90's NaN
    # guard; see set_nan_guard_flag.
    set_nan_guard_flag "$ALF_FC" "$F90OPTFLAGS" -fno-finite-math-only -fhonor-nans
    F90OPTFLAGS="$F90OPTFLAGS $NAN_GUARD_FLAG"
    F90USEFULFLAGS="$GNUUSEFULFLAGS"
    LIB_BLAS_LAPACK="-llapack -lblas -fopenmp"
    if [ "${HDF5_ENABLED}" = "1" ]; then
      set_hdf5_flags gcc gfortran g++ || return 1
    fi
  ;;

  #Intel (as Hybrid code)
  INTEL)
    F90OPTFLAGS="$INTELOPTFLAGS"
    F90USEFULFLAGS="$INTELUSEFULFLAGS"
    ALF_FC="$INTELCOMPILER"
    find_mkl_flag || return 1
    LIB_BLAS_LAPACK="${INTELMKL}"
    if [ "${HDF5_ENABLED}" = "1" ]; then
      set_intelcc
      set_intelcxx
      set_hdf5_flags "$INTELCC" ifort "$INTELCXX" || return 1
    fi
  ;;

  #Intel (as Hybrid code)
  INTELLLVM|INTELX)
    F90OPTFLAGS="$INTELLLVMOPTFLAGS"
    F90USEFULFLAGS="$INTELLLVMUSEFULFLAGS"
    ALF_FC="$INTELLLVMCOMPILER"
    INTELMKL="-qmkl"
    LIB_BLAS_LAPACK="${INTELMKL}"
    if [ "${HDF5_ENABLED}" = "1" ]; then
      set_intelcc
      set_intelcxx
      set_hdf5_flags "$INTELCC" ifx "$INTELCXX" || return 1
    fi
  ;;

  #Cedar (as Hybrid code)
  CEDAR)
    F90OPTFLAGS="$INTELOPTFLAGS"
    F90USEFULFLAGS="$INTELUSEFULFLAGS"
    ALF_FC="$INTELCOMPILER"
    LIB_BLAS_LAPACK="$INTELMKL"
    if [ "${HDF5_ENABLED}" = "1" ]; then
       INC_HDF5="-I$HDF5_DIR/include"
       LIB_HDF5="-L$HDF5_DIR/lib $HDF5_DIR/lib/libhdf5hl_fortran.a $HDF5_DIR/lib/libhdf5_hl.a"
       LIB_HDF5="$LIB_HDF5 $HDF5_DIR/lib/libhdf5_fortran.a $HDF5_DIR/lib/libhdf5.a -lz -ldl -lm -Wl,-rpath -Wl,$HDF5_DIR/lib  -lsz"
    fi
  ;;

  #PGI
  PGI)
    F90OPTFLAGS="$PGIOPTFLAGS"
    F90USEFULFLAGS="$PGIUSEFULFLAGS"
    if [ "$MPICOMP" -eq "0" ]; then
      ALF_FC="pgfortran"
    else
      ALF_FC="mpifort"
      printf "\n${RED}   !! Compiler set to 'mpifort' !!\n" 1>&2
      printf "If this is not your PGI MPI compiler you have to set it manually through e.g.\n" 1>&2
      printf "    'export ALF_FC=<mpicompiler>'${NC}\n" 1>&2
    fi
    LIB_BLAS_LAPACK="-llapack -lblas"
    if [ "${HDF5_ENABLED}" = "1" ]; then
      set_hdf5_flags pgcc pgfortran pgc++ || return 1
    fi

  ;;

  #LRZ enviroment
  SUPERMUC-NG|NG)
    module load hdf5/1.10.7-intel21
    printf "\n${RED}   !!   unsetting  FORT_BLOCKSIZE  !!${NC}\n" 1>&2
    unset FORT_BLOCKSIZE

    F90OPTFLAGS="$INTELOPTFLAGS"
    F90USEFULFLAGS="$INTELUSEFULFLAGS"
    ALF_FC="mpiifort"
    LIB_BLAS_LAPACK="$MKL_LIB"
    LIB_HDF5="$HDF5_F90_SHLIB $HDF5_SHLIB"
    INC_HDF5="$HDF5_INC"
  ;;

  #JUWELS enviroment
  JUWELS)
    module load Intel
    module load IntelMPI
    module load imkl
    module load HDF5/1.10.6

    F90OPTFLAGS="$INTELOPTFLAGS"
    F90USEFULFLAGS="$INTELUSEFULFLAGS"
    ALF_FC="mpiifort"
    find_mkl_flag || return 1
    LIB_BLAS_LAPACK="${INTELMKL}"
    LIB_HDF5="-lhdf5_fortran"
    INC_HDF5=""
  ;;

  #NHR@FAU Fritz cluster
  FRITZ)
    module load intel
    module load intelmpi
    module load mkl

    F90OPTFLAGS="$INTELOPTFLAGS"
    F90USEFULFLAGS="$INTELUSEFULFLAGS"
    ALF_FC="$INTELCOMPILER"
    find_mkl_flag || return 1
    LIB_BLAS_LAPACK="${INTELMKL}"
    if [ "${HDF5_ENABLED}" = "1" ]; then
      set_intelcc
      set_intelcxx
      set_hdf5_flags "$INTELCC" ifort "$INTELCXX" || return 1
    fi
  ;;

  #IntelX for PKS cluster. -march=core-avx2 is the common baseline of a mixed
  #Intel/AMD pool, so this is the case that runs anywhere; PKS_ZEN_MKL is the
  #production target and trades that breadth for the Zen-5 nodes.
  PKS)
    load_intel_env || return 1
    ALF_FC="$INTELLLVMCOMPILER"
    F90OPTFLAGS="${INTELLLVMOPTFLAGS/-xHost/-march=core-avx2}"
    # -fp-model=fast=2 deletes control_mod.F90's NaN guard; see set_nan_guard_flag.
    set_nan_guard_flag "$ALF_FC" "$F90OPTFLAGS" -fhonor-nans -fno-finite-math-only -fp-model=fast=1
    F90OPTFLAGS="$F90OPTFLAGS $NAN_GUARD_FLAG"
    F90USEFULFLAGS="$INTELLLVMUSEFULFLAGS"
    LIB_BLAS_LAPACK="-qmkl"
    if [ "${HDF5_ENABLED}" = "1" ]; then
      set_intelcc
      set_intelcxx
      set_hdf5_flags "$INTELCC" ifx "$INTELCXX" || return 1
    fi
  ;;

  #IntelX + AOCL for the Zen nodes of the PKS cluster. Jobs built with this must
  #be constrained to those nodes: the -march targeted here emits instructions
  #the pool's Intel nodes cannot decode, giving SIGILL rather than a fallback.
  #
  #Superseded by PKS_ZEN_MKL for production -- AOCL loses to MKL once the node is
  #packed -- and kept as the AOCL arm of that comparison, which is also what
  #PKS_GNU_ZEN's compiler axis reads against.
  PKS_ZEN)
    load_intel_env || return 1
    module load aocl/5.3-gcc-ST
    set_aocl_flags
    ALF_FC="$INTELLLVMCOMPILER"
    # Fatal rather than best-effort: an empty BEST_MARCH removes -xHost and puts
    # nothing back, so a total probe failure builds generic x86-64 -- no AVX2,
    # slower than the plain PKS baseline, from a build that otherwise succeeds.
    best_march "$ALF_FC" znver5 znver4 core-avx2 || return 1
    # -static-intel replaces -static: AOCL links as a shared library, which a
    # fully static link cannot resolve.
    F90OPTFLAGS="${INTELLLVMOPTFLAGS/-xHost/$BEST_MARCH}"
    F90OPTFLAGS="${F90OPTFLAGS/-static /-static-intel }"
    # -fp-model=fast=2 deletes control_mod.F90's NaN guard; see set_nan_guard_flag.
    set_nan_guard_flag "$ALF_FC" "$F90OPTFLAGS" -fhonor-nans -fno-finite-math-only -fp-model=fast=1
    F90OPTFLAGS="$F90OPTFLAGS $NAN_GUARD_FLAG"
    F90USEFULFLAGS="$INTELLLVMUSEFULFLAGS"
    LIB_BLAS_LAPACK="$AOCL_BLAS_LAPACK"
    if [ "${HDF5_ENABLED}" = "1" ]; then
      set_intelcc
      set_intelcxx
      set_hdf5_flags "$INTELCC" ifx "$INTELCXX" || return 1
    fi
  ;;

  #IntelX + MKL for the Zen-5 nodes of the PKS cluster. Same SIGILL constraint
  #as PKS_ZEN: the -march targeted here emits instructions the pool's Intel
  #nodes cannot decode.
  #
  #MKL rather than PKS_ZEN's AOCL because the two libraries are equivalent on an
  #idle core but not on a full node -- BLIS packs A and B on every call, which is
  #free solo and not free when every core is competing for the same memory
  #bandwidth, and this cluster's nodes run packed with single-core chains.
  #
  #MKL dispatches on CPUID *vendor*, not on features, so on AMD it needs the
  #vendor-check override LD_PRELOADed at *run* time or it takes a conservative
  #kernel and this target is roughly half speed with nothing to say about it.
  #The override is a runtime artefact, not a link-time one: see scripts/mkl_shim.py
  #in the parent repository, which builds it and checks it engaged.
  PKS_ZEN_MKL)
    load_intel_env || return 1
    ALF_FC="$INTELLLVMCOMPILER"
    # Fatal rather than best-effort, as in PKS_ZEN: an empty BEST_MARCH removes
    # -xHost and puts nothing back, so a total probe failure builds generic
    # x86-64 -- no AVX2, slower than the plain PKS baseline it was meant to beat.
    best_march "$ALF_FC" znver5 znver4 core-avx2 || return 1
    # -static-intel replaces -static, and here that is a correctness requirement
    # rather than PKS_ZEN's link fix: LD_PRELOAD can only interpose a symbol that
    # is resolved dynamically, so a fully static MKL would leave the shim doing
    # nothing at all -- silently, since a preload that binds no symbol is not an
    # error. The Intel runtime stays static, which is all -static bought here.
    F90OPTFLAGS="${INTELLLVMOPTFLAGS/-xHost/$BEST_MARCH}"
    F90OPTFLAGS="${F90OPTFLAGS/-static /-static-intel }"
    # -fp-model=fast=2 deletes control_mod.F90's NaN guard; see set_nan_guard_flag.
    set_nan_guard_flag "$ALF_FC" "$F90OPTFLAGS" -fhonor-nans -fno-finite-math-only -fp-model=fast=1
    F90OPTFLAGS="$F90OPTFLAGS $NAN_GUARD_FLAG"
    F90USEFULFLAGS="$INTELLLVMUSEFULFLAGS"
    # Threaded MKL deliberately, exactly as measured. Every chain runs on one
    # core, so the thread pool is unused rather than harmful; MKL_NUM_THREADS=1
    # is exported alongside it (scripts/environments.py) so it stays that way
    # even if SLURM_CPUS_PER_TASK, which is what pyALF derives OMP_NUM_THREADS
    # from, is ever missing. -qmkl=sequential would drop the pool outright and
    # is worth pricing, but it is not the configuration the benchmark ranked.
    LIB_BLAS_LAPACK="-qmkl"
    if [ "${HDF5_ENABLED}" = "1" ]; then
      set_intelcc
      set_intelcxx
      set_hdf5_flags "$INTELCC" ifx "$INTELCXX" || return 1
    fi
  ;;

  #AOCC (classic flang) + AOCL for the Zen-5 nodes of the PKS cluster. Uses
  #AOCL's -aocc flavour, hence no -lgfortran. Same SIGILL constraint as
  #PKS_ZEN. Needs an HDF5 built by this flang: .mod is a compiler-specific
  #binary format, and one from another compiler reports as "Corrupt or Old
  #Module file".
  #
  #Not usable with AOCC 5.2 as it stands. Two separate classic-flang defects:
  #no type descriptor for a derived type declared inside a submodule (the link
  #fails on `allocate(ham_X::ham)`), and, once the type is moved to a companion
  #module so it does link, a `procedure, nopass ::` override that dispatches to
  #the *base* implementation -- the run dies with "Ham_set not defined!". Kept
  #for a future LLVM-Flang-based AOCC; scripts/benchmarks/flang_td_probe.sh in
  #the parent repository reproduces both in seconds.
  PKS_AOCC)
    module load aocc/5.2.0
    module load aocl/5.3-aocc-ST
    set_aocl_flags ""
    ALF_FC="$AOCCCOMPILER"
    best_march "$ALF_FC" znver5 znver4 x86-64-v3 || return 1
    F90OPTFLAGS="$AOCCOPTFLAGS $BEST_MARCH"
    F90USEFULFLAGS="$AOCCUSEFULFLAGS"
    LIB_BLAS_LAPACK="$AOCL_BLAS_LAPACK"
    if [ "${HDF5_ENABLED}" = "1" ]; then
      set_hdf5_flags clang flang clang++ || return 1
    fi
  ;;

  #gfortran + AOCL for the Zen-5 nodes of the PKS cluster. Uses AOCL's -gcc
  #flavour, so compiler runtime, OpenMP runtime and BLAS come from one
  #toolchain. Same SIGILL constraint as PKS_ZEN.
  PKS_GNU_ZEN)
    # znver5 needs gcc 14.1+, which the system compiler rarely is.
    # ALF_GCC_MODULE pins a version; best_march prints the target it settled on,
    # so an older module degrades visibly rather than failing.
    module load "${ALF_GCC_MODULE:-gcc}"
    module load aocl/5.3-gcc-ST
    set_aocl_flags
    ALF_FC="$GNUCOMPILER"
    best_march "$ALF_FC" znver5 znver4 x86-64-v3 || return 1
    # -fallow-argument-mismatch: see the GNU case above.
    test "$(gfortran_major)" -gt 9 && GNUOPTFLAGS="${GNUOPTFLAGS} -fallow-argument-mismatch"
    F90OPTFLAGS="$GNUOPTFLAGS $BEST_MARCH"
    # Probed rather than hard-coded, as in the GNU case: which flag restores the
    # guard against GNUOPTFLAGS' -ffast-math is a property of the gcc this
    # module happens to provide, and the probe checks it instead of assuming.
    set_nan_guard_flag "$ALF_FC" "$F90OPTFLAGS" -fno-finite-math-only -fhonor-nans
    F90OPTFLAGS="$F90OPTFLAGS $NAN_GUARD_FLAG"
    F90USEFULFLAGS="$GNUUSEFULFLAGS"
    # -fopenmp on the link line too: Prog/Makefile links with $(ALF_LIB) alone.
    LIB_BLAS_LAPACK="$AOCL_BLAS_LAPACK -fopenmp"
    if [ "${HDF5_ENABLED}" = "1" ]; then
      set_hdf5_flags gcc gfortran g++ || return 1
    fi
  ;;

  #Raven
  RAVEN)
    module purge
    module load intel/2025.2
    module load impi/2021.16
    module load hdf5-serial/1.12.2
    module load mkl/2025.2
    F90OPTFLAGS="${INTELLLVMOPTFLAGS/-xHost/-xCORE-AVX512 -qopt-zmm-usage=high}"
    F90USEFULFLAGS="$INTELLLVMUSEFULFLAGS"
    ALF_FC="$INTELLLVMCOMPILER"
    find_mkl_flag || return 1
    LIB_BLAS_LAPACK="${INTELMKL} -static-intel"
    if [ "${HDF5_ENABLED}" = "1" ]; then
      INC_HDF5="-I$HDF5_HOME/include"
      LIB_HDF5="-L$HDF5_HOME/lib $HDF5_HOME/lib/libhdf5hl_fortran.a $HDF5_HOME/lib/libhdf5_hl.a"
      LIB_HDF5="$LIB_HDF5 $HDF5_HOME/lib/libhdf5_fortran.a $HDF5_HOME/lib/libhdf5.a -lz -ldl -lm -Wl,-rpath -Wl,$HDF5_HOME/lib"
    fi
  ;;
  
  #Default (unknown machine)
  *)
    if [ "$NO_FALLBACK" = "1" ]; then
      printf "${RED}  !!     UNKNOWN MACHINE     !!${NC}\n" 1>&2
      printf "${RED}  !!  exiting configure.sh  !!${NC}\n" 1>&2
      return 1
    fi
    printf "\n" 1>&2
    printf "${RED}   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}\n" 1>&2
    printf "${RED}   !!               UNKNOWN MACHINE               !!${NC}\n" 1>&2
    printf "${RED}   !!         IGNORING PARALLEL SETTINGS         !!${NC}\n" 1>&2
    printf "${RED}   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}\n" 1>&2
    printf "\n" 1>&2
    printf "Activating fallback option with gfortran for SERIAL JOB - Deactivating MPI.\n" 1>&2
    printf "\n" 1>&2
    printf "$USAGE"
    PROGRAMMCONFIGURATION=""
    F90OPTFLAGS="-cpp -O3 -ffree-line-length-none -ffast-math"
    # -fallow-argument-mismatch was required by gfortran10 and MPICH, they changed default behaviour in v10
    test "$(gfortran_major)" -gt 9 && F90OPTFLAGS="${F90OPTFLAGS} -fallow-argument-mismatch"
    F90USEFULFLAGS=""

    ALF_FC="gfortran"
    LIB_BLAS_LAPACK="-llapack -lblas"
    if [ "${HDF5_ENABLED}" = "1" ]; then
      set_hdf5_flags gcc gfortran g++ || return 1
    fi
  ;;
esac

check_libs "$ALF_FC" "${LIB_BLAS_LAPACK}" || return 1

check_python || return 1

PROGRAMMCONFIGURATION="$STABCONFIGURATION $PROGRAMMCONFIGURATION"

if [ -n "${ALF_INC_EXT+x}" ]; then
  printf "\nAppending additional include directory '%s'\n" "${ALF_INC_EXT}"
fi

Libs="$ALF_DIR/Libraries"
ALF_INC="-I${Libs}/Modules ${ALF_INC_EXT}"
ALF_LIB="${Libs}/Modules/modules_90.a ${LIB_BLAS_LAPACK} ${Libs}/libqrref/libqrref.a ${ALF_LIB_EXT}"

if [ "${HDF5_ENABLED}" = "1" ]; then
  echo; echo "HDF5 enabled"
  ALF_INC="${ALF_INC} ${INC_HDF5}"
  ALF_LIB="${ALF_LIB} ${LIB_HDF5}"
else
  echo; echo "HDF5 disabled"
fi
export ALF_LIB

export ALF_DIR
export ALF_FC

if [ -n "${ALF_FLAGS_EXT+x}" ]; then
  printf "\nAppending additional compiler flag '%s'\n" "${ALF_FLAGS_EXT}"
fi

ALF_FLAGS_QRREF="${F90OPTFLAGS} ${ALF_FLAGS_EXT}"
# Modules need to know the programm configuration since entanglement needs MPI
ALF_FLAGS_MODULES="${F90OPTFLAGS} ${PROGRAMMCONFIGURATION} ${ALF_FLAGS_EXT}"
ALF_FLAGS_ANA="${F90USEFULFLAGS} ${F90OPTFLAGS} ${ALF_INC} ${ALF_FLAGS_EXT}"
ALF_FLAGS_PROG="${F90USEFULFLAGS} ${F90OPTFLAGS} ${PROGRAMMCONFIGURATION} ${ALF_INC} ${ALF_FLAGS_EXT}"
# Control with flags -DHDF5 -DHDF5_ZLIB -DOBS_LEGACY, which observable format to use
if [ "${HDF5_ENABLED}" = "1" ]; then
  ALF_FLAGS_MODULES="${ALF_FLAGS_MODULES} ${INC_HDF5} -DHDF5 -DHDF5_ZLIB"
  ALF_FLAGS_ANA="${ALF_FLAGS_ANA} ${INC_HDF5} -DHDF5 -DHDF5_ZLIB"
  ALF_FLAGS_PROG="${ALF_FLAGS_PROG} -DHDF5 -DHDF5_ZLIB"
fi
export ALF_FLAGS_QRREF
export ALF_FLAGS_MODULES
export ALF_FLAGS_ANA
export ALF_FLAGS_PROG

rm -r "$tmpdir"
printf "\n${GREEN}Temporary directory %s deleted${NC}\n" "$tmpdir"

printf "\nTo compile your program use:    'make'\n\n"