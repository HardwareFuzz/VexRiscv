.section .text
.globl _start
.type _start, @function

/* skiptrap_fwrite
 * - Keeps the skiptrap harness (mtvec + trap handler + PASS write)
 * - Focuses user payload on instructions that write an f-register
 * - Every f-register write is annotated with a uniform FWRITE comment
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
/* User payload: only instructions that write an f-register    */
/* ----------------------------------------------------------- */
user_code:
    la      t2, f32_inputs
    flw     f0, 0(t2)          /* FWRITE f0 := load +1.5f (0x3FC00000) */
    flw     f1, 4(t2)          /* FWRITE f1 := load -2.0f (0xC0000000) */
    flw     f2, 8(t2)          /* FWRITE f2 := load +4.0f (0x40800000) */
    flw     f3, 12(t2)         /* FWRITE f3 := load +0.75f (0x3F400000) */

    li      t0, 0x40400000
    fmv.w.x f4, t0             /* FWRITE f4 := literal 3.0f pattern (0x40400000) */

    fadd.s  f5, f0, f0         /* FWRITE f5 := f0 + f0 -> 3.0f */
    fsub.s  f6, f2, f0         /* FWRITE f6 := f2 - f0 -> 2.5f */
    fmul.s  f7, f0, f1         /* FWRITE f7 := f0 * f1 -> -3.0f */
    fdiv.s  f8, f2, f0         /* FWRITE f8 := f2 / f0 -> ~2.666667f */
    fsqrt.s f9, f2             /* FWRITE f9 := sqrt(f2) -> 2.0f */
    fmadd.s f10, f0, f1, f2    /* FWRITE f10 := f0*f1 + f2 -> 1.0f */
    fmsub.s f11, f2, f0, f3    /* FWRITE f11 := f2*f0 - f3 -> 5.25f */
    fnmadd.s f12, f1, f3, f2   /* FWRITE f12 := -(f1*f3) + f2 -> 5.5f */
    fnmsub.s f13, f2, f3, f0   /* FWRITE f13 := -(f2*f3) - f0 -> -4.5f */
    fsgnj.s  f14, f1, f2       /* FWRITE f14 := |f1| with sign of f2 -> +2.0f */
    fsgnjn.s f15, f1, f2       /* FWRITE f15 := |f1| with inverted sign -> -2.0f */
    fsgnjx.s f16, f0, f1       /* FWRITE f16 := |f0| with XOR sign -> -1.5f */
    fmin.s   f17, f0, f1       /* FWRITE f17 := min(f0,f1) -> -2.0f */
    fmax.s   f18, f0, f2       /* FWRITE f18 := max(f0,f2) -> 4.0f */
    li      t1, -7
    fcvt.s.w f19, t1           /* FWRITE f19 := float(-7) -> -7.0f */
    li      t1, 9
    fcvt.s.wu f20, t1          /* FWRITE f20 := float_u(9) -> 9.0f */

    la      t3, f64_inputs
    la      t6, f64_results
    fld     f23, 0(t3)         /* FWRITE f23 := load +1.5 (0x3FF8000000000000) */
    fld     f24, 8(t3)         /* FWRITE f24 := load -2.5 (0xC004000000000000) */
    fld     f25, 16(t3)        /* FWRITE f25 := load +3.25 (0x400A000000000000) */

    fcvt.s.d f21, f24          /* FWRITE f21 := narrow -2.5 -> -2.5f */
    fcvt.s.d f22, f25          /* FWRITE f22 := narrow 3.25 -> 3.25f */

    fcvt.d.s f26, f5           /* FWRITE f26 := widen 3.0f -> 3.0 */
    fsd     f26, 0(t6)
    li      t4, -12
    fcvt.d.w f27, t4           /* FWRITE f27 := double(-12) -> -12.0 */
    fsd     f27, 8(t6)
    li      t4, 13
    fcvt.d.wu f28, t4          /* FWRITE f28 := double_u(13) -> 13.0 */
    fsd     f28, 16(t6)

    fadd.d  f29, f23, f25      /* FWRITE f29 := f23 + f25 -> 4.75 */
    fsd     f29, 24(t6)
    fsub.d  f29, f25, f24      /* FWRITE f29 := f25 - f24 -> 5.75 */
    fsd     f29, 32(t6)
    fmul.d  f29, f23, f24      /* FWRITE f29 := f23 * f24 -> -3.75 */
    fsd     f29, 40(t6)
    fdiv.d  f29, f25, f23      /* FWRITE f29 := f25 / f23 -> ~2.166667 */
    fsd     f29, 48(t6)
    fsqrt.d f29, f25           /* FWRITE f29 := sqrt(f25) -> ~1.802776 */
    fsd     f29, 56(t6)
    fmadd.d f29, f23, f25, f24 /* FWRITE f29 := f23*f25 + f24 -> 2.375 */
    fsd     f29, 64(t6)
    fmsub.d f29, f25, f23, f24 /* FWRITE f29 := f25*f23 - f24 -> 7.375 */
    fsd     f29, 72(t6)
    fnmadd.d f29, f24, f23, f25/* FWRITE f29 := -(f24*f23) + f25 -> 7.0 */
    fsd     f29, 80(t6)
    fnmsub.d f29, f25, f24, f23/* FWRITE f29 := -(f25*f24) - f23 -> 6.625 */
    fsd     f29, 88(t6)
    fcvt.d.s f29, f9           /* FWRITE f29 := widen f9 -> 2.0 */
    fsd     f29, 96(t6)

    la      t5, f32_results
    fsw     f5, 0(t5)
    fsw     f6, 4(t5)
    fsw     f7, 8(t5)
    fsw     f8, 12(t5)
    fsw     f9, 16(t5)
    fsw     f10, 20(t5)
    fsw     f11, 24(t5)
    fsw     f12, 28(t5)
    fsw     f13, 32(t5)
    fsw     f14, 36(t5)
    fsw     f15, 40(t5)
    fsw     f16, 44(t5)
    fsw     f17, 48(t5)
    fsw     f18, 52(t5)
    fsw     f19, 56(t5)
    fsw     f20, 60(t5)
    fsw     f21, 64(t5)
    fsw     f22, 68(t5)


    ecall                       /* exercise skiptrap */
    .word   0xffffffff          /* illegal instruction skip */

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
f32_inputs:
    .word 0x3FC00000   /* +1.5f */
    .word 0xC0000000   /* -2.0f */
    .word 0x40800000   /* +4.0f */
    .word 0x3F400000   /* +0.75f */

.align 3
f64_inputs:
    .dword 0x3FF8000000000000   /* +1.5 */
    .dword 0xC004000000000000   /* -2.5 */
    .dword 0x400A000000000000   /* +3.25 */

.align 2
f32_results:
    .rept 18
        .word 0
    .endr

.align 3
f64_results:
    .rept 13
        .dword 0
    .endr

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

/* ----------------------------------------------------------- */
/* Failure paths: write code to 0xF00FFF24 then spin           */
/* ----------------------------------------------------------- */
.section .text
fail_code_0xE1:
    li      t2, 0xF00FFF24
    li      t0, 0xE1
    sw      t0, 0(t2)
1:  j       1b
fail_code_0xE2:
    li      t2, 0xF00FFF24
    li      t0, 0xE2
    sw      t0, 0(t2)
1:  j       1b
