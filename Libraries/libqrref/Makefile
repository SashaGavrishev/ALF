OBJS=zgeqr2.o zgeqrf.o zlarf.o zlarfb.o zlarfg.o zlarft.o zung2r.o zungqr.o  zlapmr.o

# See Libraries/Modules/Makefile: plain `ar` cannot index -ipo's objects, and an
# old xiar produces an unindexed archive without complaining.
ifeq ($(origin ALF_AR),undefined)
ALF_AR := $(if $(filter -ipo,$(ALF_FLAGS_QRREF)),$(shell command -v llvm-ar 2>/dev/null || command -v xiar 2>/dev/null || echo ar),ar)
endif

all: $(OBJS)
	$(ALF_AR) -r libqrref.a $(OBJS)

%.o: %.f
	$(ALF_FC) -c $(ALF_FLAGS_QRREF) $< 

clean: 
	rm -f $(OBJS) libqrref.a
