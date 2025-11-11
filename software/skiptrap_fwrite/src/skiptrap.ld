OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
  onChipRam (W!RX) : ORIGIN = 0x80000000, LENGTH = 128K
}

SECTIONS
{
  .text : {
    . = ALIGN(4);
    KEEP(*(.text.start))
    *(.text*)
    *(.rodata*)
  } > onChipRam

  .data : {
    . = ALIGN(4);
    *(.data*)
  } > onChipRam

  .bss (NOLOAD) : {
    . = ALIGN(4);
    __bss_start = .;
    *(.bss*)
    *(COMMON)
    __bss_end = .;
  } > onChipRam

  /* Place the tohost region at VexRiscv harness MMIO pass/fail addresses */
  . = 0xF00FFF20;
  .tohost 0xF00FFF20 : {
    KEEP(*(.tohost))
  }
}

