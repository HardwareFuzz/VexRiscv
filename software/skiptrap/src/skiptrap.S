.section .text
.globl _start
.type _start, @function

/* Simple skip-trap framework for VexRiscv (RV32, IMAFDC+Zicsr compatible)
 * - Installs mtvec = trap_handler
 * - Optionally enables FP (sets FS=Dirty, clears fcsr)
 * - Executes some user code with register/memory ops and deliberate traps
 * - On completion, writes 1 to 0xF00FFF20 (PASS) using the .tohost symbol
 */

.section .text.start
_start:
    /* Set machine trap vector */
    la      t0, trap_handler
    csrw    mtvec, t0

    /* Enable FP CSRs (FS=11) so FP ops won't trap if used */
    csrr    t0, mstatus
    li      t1, 0x00003000       /* FS=Dirty */
    or      t0, t0, t1
    csrw    mstatus, t0
    csrw    fcsr, x0             /* clear floating-point status */

    j       user_code

/* ----------------------------------------------------------- */
/* User payload: registers, memory stores, and some traps      */
/* ----------------------------------------------------------- */
user_code:
    /* General-purpose register writes */
    li      s0, 0x12345678
    li      s1, 0x89abcdef
    add     s2, s0, s1

    /* Memory write/read in onChipRam */
    la      t2, buf
    sw      s0, 0(t2)
    lw      t3, 0(t2)

    /* Deliberate traps we will skip: */
    ecall                       /* environment call (mcause = 11 in M-mode) */
    /* Misaligned load (will trap if alignment checks enabled) */
    lw      t4, 1(t2)
    /* Illegal instruction (non-decodable 32-bit word) */
    .word   0xffffffff

exit:
    /* Report success: write 0 to .tohost placed at 0xF00FFF20 */
    li      t0, 0
    la      t1, tohost
    sw      t0, 0(t1)
1:
    j       1b

/* ----------------------------------------------------------- */
/* Trap handler: skip the offending instruction and continue   */
/* ----------------------------------------------------------- */
.align  2
trap_handler:
    csrr    t0, mepc             /* faulting PC */
    csrr    t1, mcause           /* trap cause */
    csrr    t4, mtval

    /* Strip interrupt bit to get exception code */
    slli    t5, t1, 1
    srli    t1, t5, 1

    /* Default length assumes compressed (2B) */
    li      t2, 2

    /* For illegal instruction, mtval holds encoding => reuse it */
    li      t3, 2                /* illegal instruction */
    beq     t1, t3, decode_length
    /* For instruction access fault/page fault, still decode length from memory */
    li      t3, 1                /* instruction access fault */
    beq     t1, t3, read_mem_half
    li      t3, 12               /* instruction page fault */
    beq     t1, t3, read_mem_half
    /* For other traps (ecall, load/store, misalign, etc.), read the halfword from mepc */
read_mem_half:
    lhu     t4, 0(t0)

decode_length:
    andi    t4, t4, 3
    li      t3, 3
    bne     t4, t3, compressed_len
    li      t2, 4                /* standard 32-bit instruction */
    j       update_mepc

compressed_len:
    li      t2, 2                /* compressed instruction */

update_mepc:
    add     t0, t0, t2           /* skip offending instruction */
    csrw    mepc, t0
    csrw    mcause, x0
    csrw    mtval, x0
    mret

/* ----------------------------------------------------------- */
/* Simple data                                                 */
/* ----------------------------------------------------------- */
.section .data
.align 2
buf:
    .word 0

/* ----------------------------------------------------------- */
/* VexRiscv harness PASS/FAIL region                           */
/* ----------------------------------------------------------- */
.section .tohost,"aw",@progbits
.align  2
.globl  tohost
.globl  fromhost
tohost:
    .word 0
fromhost:
    .word 0
