.PHONY : lib clean

LIB=modules_90.a

SRCS = Mat_subroutines_mod.F90 \
	alf_hdf5_mod.F90 \
	check_omp_num_threads_mod.F90 \
	entanglement_mod.F90 \
	errors_mod.F90 \
	files_mod.F90 \
	fourier_mod.F90 \
	histograms_mod.F90 \
	histograms_v2_mod.F90 \
	iso8601_datetime_mod.F90 \
	lattices_interface_mod.F90 \
	lattices_v3_mod.F90 \
	log_mesh_mod.F90 \
	matrix_mod.F90 \
	maxent_mod.F90 \
	maxent_stoch_mod.F90 \
	mpi_shared_mem_mod_v2.F90 \
	mymats_mod.F90 \
	natural_constants_mod.F90 \
	precdef_mod.F90 \
	random_wrap_mod.F90 \
	runtime_error_mod.F90

# Dependency helper variables
DEPSFILE := .deps.mk
DEPSGEN := ../../Prog/gen_deps.py

lib: $(LIB) libfakeintel.so

# OBJS and MODS are auto-generated into $(DEPSFILE) by gen_deps.py
-include $(DEPSFILE)

# Plain `ar` cannot index the objects -ipo emits: it writes an archive with no
# symbol table and the link fails with "archive has no index". Which archiver
# can depends on the compiler -- xiar is Intel's tool for classic ifort, while
# ifx is LLVM-based and emits bitcode that llvm-ar indexes. llvm-ar is tried
# first because a stray old xiar on PATH (/usr/local/bin, left by a previous
# Intel install) accepts the objects and silently produces an unindexed archive
# rather than failing. Set ALF_AR to override the choice.
ALF_IPO := $(filter -ipo,$(ALF_FLAGS_MODULES))
ifeq ($(origin ALF_AR),undefined)
ALF_AR := $(if $(ALF_IPO),$(shell command -v llvm-ar 2>/dev/null || command -v xiar 2>/dev/null || echo ar),ar)
endif
ifneq ($(ALF_IPO),)
ifeq ($(notdir $(ALF_AR)),ar)
$(warning -ipo needs llvm-ar or xiar; neither found, so this archive will have no symbol index)
endif
endif

$(LIB): $(DEPSFILE) $(OBJS)
	$(ALF_AR) -r $(LIB) $(OBJS)

lattices_x86-64.so: runtime_error_mod.F90 lattices_interface_mod.F90 matrix_mod.F90 lattices_v3_mod.F90
	(make clean)
	gfortran -O3 -march=x86-64 -c runtime_error_mod.F90
	gfortran -O3 -march=x86-64 -c matrix_mod.F90
	gfortran -O3 -march=x86-64 -c lattices_v3_mod.F90
	gfortran -O3 -march=x86-64 -shared -fPIC lattices_interface_mod.F90 -o lattices_x86-64.so \
			runtime_error_mod.o matrix_mod.o lattices_v3_mod.o

lattices_armv8.4-a.so: runtime_error_mod.F90 lattices_interface_mod.F90 matrix_mod.F90 lattices_v3_mod.F90
	(make clean)
	gfortran -O3 -march=armv8.4-a -c runtime_error_mod.F90
	gfortran -O3 -march=armv8.4-a -c matrix_mod.F90
	gfortran -O3 -march=armv8.4-a -c lattices_v3_mod.F90
	gfortran -O3 -march=armv8.4-a -shared -fPIC lattices_interface_mod.F90 -o lattices_armv8.4-a.so \
			runtime_error_mod.o matrix_mod.o lattices_v3_mod.o

%.o: %.F90
	$(ALF_FC) -c $(ALF_FLAGS_MODULES) $<

libfakeintel.so: fakeintel.c
	@for cc in gcc clang icc icx cc; do \
		if command -v $$cc > /dev/null 2>&1; then \
			$$cc -shared -fPIC -o libfakeintel.so fakeintel.c; \
			break; \
		fi; \
	done; \
	if [ ! -f libfakeintel.so ]; then \
		echo "No C compiler found, libfakeintel.so not created." 1>&2; \
	fi

entanglement_mod.o: entanglement_mod.F90
	$(ALF_FC) -c $(shell echo $(ALF_FLAGS_MODULES) | sed 's| -pedantic||') $<

$(DEPSFILE): $(SRCS) $(DEPSGEN)
	python3 $(DEPSGEN) $(SRCS) > $(DEPSFILE)

clean: $(DEPSFILE)
	rm -f $(OBJS) $(MODS) $(LIB) $(DEPSFILE) libfakeintel.so

#unused modules: histograms histograms_v2 log_mesh natural_constants
#unused, except for in Prog/FFA_Orginals/: precdef
