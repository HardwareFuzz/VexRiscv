RISCV_PREFIX ?= riscv64-unknown-elf-
CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump

PROJ    := skiptrap_fwrite
OUTDIR  := build
SRCDIR  := src

# RV32 with max extensions used in our sim (IMAFDC + Zicsr)
ARCH    ?= rv32imafdc_zicsr
ABI     ?= ilp32

INCS    :=
CFLAGS  := -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -ffreestanding -O2 -Wall -Wextra
LDFLAGS := -T $(SRCDIR)/skiptrap.ld -Wl,-Map,$(OUTDIR)/$(PROJ).map -nostdlib -nostartfiles

SRC_ASM := $(SRCDIR)/skiptrap_fwrite.S
OBJ     := $(OUTDIR)/skiptrap_fwrite.o

.PHONY: all clean dump

all: $(OUTDIR)/$(PROJ).elf $(OUTDIR)/$(PROJ).hex $(OUTDIR)/$(PROJ).asm
	@echo "done"

$(OUTDIR):
	mkdir -p $(OUTDIR)

$(OBJ): $(SRC_ASM) | $(OUTDIR)
	$(CC) $(CFLAGS) -c -o $@ $<

$(OUTDIR)/$(PROJ).elf: $(OBJ) $(SRCDIR)/skiptrap.ld | $(OUTDIR)
	$(CC) $(CFLAGS) -o $@ $(OBJ) $(LDFLAGS)

$(OUTDIR)/$(PROJ).hex: $(OUTDIR)/$(PROJ).elf
	$(OBJCOPY) -O ihex $^ $@

$(OUTDIR)/$(PROJ).asm: $(OUTDIR)/$(PROJ).elf
	$(OBJDUMP) -S -d $^ > $@

dump: $(OUTDIR)/$(PROJ).asm

clean:
	rm -rf $(OUTDIR)
