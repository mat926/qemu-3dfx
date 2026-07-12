FXLIB=../../fxlib
CROSS?=
CC=$(CROSS)gcc
CRT_CFLAGS:=$(shell printf 'int main(void){return 0;}\n' | $(CC) -x c -mcrtdll=msvcrt-os -c - -o /dev/null >/dev/null 2>&1 && printf '%s' '-mcrtdll=msvcrt-os')
CFLAGS=-march=x86-64-v2 -mtune=generic -mfpmath=sse
CFLAGS+=-pipe -I$(FXLIB) -Wall -Wextra -Werror
CFLAGS+=$(CRT_CFLAGS)
OUTDIR?=build

all: instdrv.exe fxmemmap.vxd fxptl.sys shasum

instdrv.exe: instdrv.c
	@if [ ! -d ../$(OUTDIR) ]; then exit 1; fi
	@echo "  LD  $@"
	@$(CC) $(CFLAGS) -s -o ../$(OUTDIR)/$@ $< ../$(OUTDIR)/fxlibnt.o

fxmemmap.vxd: fxmemmap.xxd
	@echo "  DRV $@"
	@xxd -r $< ../$(OUTDIR)/$@

fxptl.sys: fxptl.xxd
	@echo "  DRV $@"
	@xxd -r $< ../$(OUTDIR)/$@

shasum: shasum.txt
	@shasum ../$(OUTDIR)/fxmemmap.vxd ../$(OUTDIR)/fxptl.sys | sed "s/.\.\.\/$(OUTDIR)\///" | diff - $<
