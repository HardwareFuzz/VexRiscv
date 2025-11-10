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

    /* Additional byte/halfword stores for trace validation */
    la      t2, buf_byte
    sb      s0, 0(t2)           /* expect low byte 0x78 */
    la      t2, buf_half
    sh      s0, 0(t2)           /* expect low half 0x5678 */

    /* ------------------------------------------------------- */
    /* Additional register and memory ops + AMO tests          */
    /* ------------------------------------------------------- */
    /* More GP writes */
    li      s3, 0x0badc0de
    li      s4, 0x13579bdf

    /* Second buffer write/read */
    la      t2, buf2
    sw      s4, 0(t2)
    lw      t3, 0(t2)

    /* AMO tests: result goes to s5 (x21) each time */
    /* 1) AMOSWAP: mem <- 0x11223344, s5 <- old (0xCAFEBABE) */
    la      a0, amo1
    li      a1, 0x11223344
    amoswap.w s5, a1, (a0)
    /* 2) AMOADD: mem <- old + 5 (0x00000015), s5 <- old (0x00000010) */
    la      a0, amo2
    li      a1, 5
    amoadd.w s5, a1, (a0)
    /* 3) AMOOR:  mem <- old | 0x0000F0F0 (=0x00F0F0F0), s5 <- old (0x00F00000) */
    la      a0, amo3
    li      a1, 0x0000F0F0
    amoor.w  s5, a1, (a0)
    /* 4) AMOAND: mem <- old & 0x00FF00FF (=0x00FF00FF), s5 <- old (0xFFFF00FF) */
    la      a0, amo4
    li      a1, 0x00FF00FF
    amoand.w s5, a1, (a0)
    /* 5) AMOMIN: mem <- min(-2, 5) = -2, s5 <- old (-2) */
    la      a0, amo5
    li      a1, 5
    amomin.w s5, a1, (a0)
    /* 6) AMOMAX: mem <- max(3, 5) = 5, s5 <- old (3) */
    la      a0, amo6
    li      a1, 5
    amomax.w s5, a1, (a0)

    /* ------------------------------------------------------- */
    /* Floating-point tests (SINGLE precision)                  */
    /* f0 = 1.5f;  f1 = f0 + f0 = 3.0f                          */
    /* Mirror to integer via fmv.x.w (x31 = 0x40400000)         */
    /* And store to memory via fsw (f32_out = 0x40400000)       */
    /* ------------------------------------------------------- */
    la      t2, f32_a
    flw     f0, 0(t2)
    fadd.s  f1, f0, f0
    fmv.x.w t6, f1
    la      t2, f32_out
    fsw     f1, 0(t2)

    /* More single-precision ops and stores for verification */
    /* f2 = f1 - f0 = 1.5f */
    fsub.s  f2, f1, f0
    la      t2, f32_sub_out
    fsw     f2, 0(t2)
    /* f3 = f0 * f0 = 2.25f (0x40100000) */
    fmul.s  f3, f0, f0
    la      t2, f32_mul_out
    fsw     f3, 0(t2)
    /* f4 = f1 / f0 = 2.0f (0x40000000) */
    fdiv.s  f4, f1, f0
    la      t2, f32_div_out
    fsw     f4, 0(t2)
    /* Integer <-> float conversions */
    fcvt.w.s t5, f1
    la      t2, f32_i_out
    sw      t5, 0(t2)          /* expect 3 */
    fcvt.s.w f5, t5
    la      t2, f32_cvt_back_out
    fsw     f5, 0(t2)          /* expect 3.0f (0x40400000) */
    /* Sign injection */
    fsgnj.s  f6, f0, f0        /* +1.5f */
    la      t2, f32_sgnj_out
    fsw     f6, 0(t2)
    fsgnjn.s f7, f0, f0        /* -1.5f = 0xBFC00000 */
    la      t2, f32_sgnjn_out
    fsw     f7, 0(t2)
    fsgnjx.s f8, f0, f0        /* +1.5f */
    la      t2, f32_sgnjx_out
    fsw     f8, 0(t2)
    /* Min/Max */
    fmin.s  f9,  f0, f1        /* 1.5f */
    la      t2, f32_min_out
    fsw     f9, 0(t2)
    fmax.s  f10, f0, f1        /* 3.0f */
    la      t2, f32_max_out
    fsw     f10, 0(t2)

    /* Extra fused multiply-add/sub and comparisons */
    fmadd.s  fa2, f0, f0, f0    /* 3.75f -> 0x40700000 */
    fnmsub.s fa3, f0, f0, f0    /* -0.75f -> 0xBF400000 */
    fmadd.s  fa4, f1, f0, f0    /* 6.0f -> 0x40C00000 */
    fmsub.s  fa5, f1, f0, f0    /* 3.0f -> 0x40400000 */

    fcvt.wu.s t6, f1
    la      t2, f32_iwu_out
    sw      t6, 0(t2)           /* expect 3 */
    fcvt.s.wu fa6, t6
    la      t2, f32_wu_back_out
    fsw     fa6, 0(t2)          /* expect 3.0f */

    feq.s   t0, f0, f0
    la      t2, f32_feq_out
    sw      t0, 0(t2)           /* expect 1 */
    flt.s   t1, f0, f1
    la      t2, f32_flt_out
    sw      t1, 0(t2)           /* expect 1 */
    fle.s   t2, f0, f1
    la      t3, f32_fle_out
    sw      t2, 0(t3)           /* expect 1 */
    fclass.s t3, f0
    la      t4, f32_fclass_out
    sw      t3, 0(t4)           /* positive normal => 0x10 */

    /* ------------------------------------------------------- */
    /* Double-precision tests                                  */
    /* fd2 = 1.5; fd3 = fd2 + fd2 = 3.0; store and convert     */
    /* ------------------------------------------------------- */
    la      t2, f64_a
    fld     ft2, 0(t2)
    fadd.d  ft3, ft2, ft2
    la      t2, f64_out
    fsd     ft3, 0(t2)         /* expect 0x4008000000000000 */
    fcvt.w.d t3, ft3
    la      t2, f64_i_out
    sw      t3, 0(t2)          /* expect 3 */
    fcvt.d.w ft4, t3
    la      t2, f64_cvt_back_out
    fsd     ft4, 0(t2)         /* expect 0x4008000000000000 */

    /* Extra double-precision ops */
    fmul.d   fs2, ft2, ft2      /* 2.25 -> 0x4002000000000000 */
    fmadd.d  fs3, ft2, ft2, ft2 /* 3.75 -> 0x400E000000000000 */
    fmsub.d  fs4, ft3, ft2, ft2 /* 3.0 -> 0x4008000000000000 */
    fsub.d   fs5, ft3, ft2      /* 1.5 -> 0x3FF8000000000000 */

    /* Targeted stress: fnmadd.s and fmax.d canonical NaN behavior */
    la      t2, f32_fnmadd_src
    flw     fs2, 0(t2)          /* f18 */
    flw     fs4, 4(t2)          /* f20 */
    flw     fs7, 8(t2)          /* f23 */
    flw     fs6, 12(t2)         /* seed for f22 */
    fnmadd.s fs6, fs2, fs4, fs7 /* expect 0xF7FF839C */
    la      t2, f32_fnmadd_out
    fsw     fs6, 0(t2)

    la      t2, f64_fmax_src
    fld     fs2, 0(t2)          /* f18 */
    fld     fs4, 8(t2)          /* f20 */
    fld     fs3, 16(t2)         /* seed for f19 */
    fmax.d  fs3, fs2, fs4       /* expect canonical NaN */
    la      t2, f64_fmax_out
    fsd     fs3, 0(t2)

    /* ------------------------------------------------------- */
    /* fmv.w.x : move integer bitpattern into float register    */
    /* int 0x3F800000 (1.0f) -> f11; mirror back to x31 and store */
    /* ------------------------------------------------------- */
    li      t1, 0x3F800000
    fmv.w.x f11, t1
    la      t2, f32_from_x_out
    fsw     f11, 0(t2)         /* expect 0x3F800000 */
    fmv.x.w t6, f11
    la      t2, f32_from_x_mirror_out
    sw      t6, 0(t2)          /* expect 0x3F800000 */

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
.align 2
buf2:
    .word 0
.align 2
buf_byte:
    .word 0
.align 2
buf_half:
    .word 0
.align 2
amo1:   .word 0xCAFEBABE
amo2:   .word 0x00000010
amo3:   .word 0x00F00000
amo4:   .word 0xFFFF00FF
amo5:   .word 0xFFFFFFFE
amo6:   .word 0x00000003
.align 2
f32_a:  .word 0x3FC00000   /* 1.5f */
f32_out: .word 0x00000000  /* expected 3.0f -> 0x40400000 */
f32_sub_out: .word 0x00000000  /* 1.5f */
f32_mul_out: .word 0x00000000  /* 2.25f -> 0x40100000 */
f32_div_out: .word 0x00000000  /* 2.0f -> 0x40000000 */
f32_i_out:   .word 0x00000000  /* 3 */
f32_cvt_back_out: .word 0x00000000 /* 3.0f -> 0x40400000 */
f32_sgnj_out: .word 0x00000000 /* +1.5f */
f32_sgnjn_out: .word 0x00000000 /* -1.5f -> 0xBFC00000 */
f32_sgnjx_out: .word 0x00000000 /* +1.5f */
f32_min_out: .word 0x00000000 /* 1.5f */
f32_max_out: .word 0x00000000 /* 3.0f */
f32_iwu_out: .word 0x00000000 /* fcvt.wu.s result -> 3 */
f32_wu_back_out: .word 0x00000000 /* fcvt.s.wu result -> 3.0f */
f32_feq_out: .word 0x00000000 /* feq.s */
f32_flt_out: .word 0x00000000 /* flt.s */
f32_fle_out: .word 0x00000000 /* fle.s */
f32_fclass_out: .word 0x00000000 /* fclass.s */
.align 3
/* 64-bit constants encoded as two 32-bit words (little-endian: lo, hi) */
f64_a:
    .word 0x00000000, 0x3FF80000   /* 1.5 (double) */
.align 3
f64_out:
    .word 0x00000000, 0x00000000
.align 2
f64_i_out:
    .word 0x00000000
.align 3
f64_cvt_back_out:
    .word 0x00000000, 0x00000000
.align 2
f32_fnmadd_src:
    .word 0x495e65f4   /* f18 source */
    .word 0x2fc0aeb4   /* f20 source */
    .word 0x77ff839c   /* f23 source */
    .word 0xd6181192   /* f22 seed */
.align 2
f32_fnmadd_out:
    .word 0x00000000
.align 3
f64_fmax_src:
    .dword 0xffffffff495e65f4  /* f18 */
    .dword 0xffffffff2fc0aeb4  /* f20 */
    .dword 0xffffffffff5128cf  /* f19 seed */
.align 3
f64_fmax_out:
    .dword 0x0000000000000000
.align 2
f32_from_x_out: .word 0x00000000
f32_from_x_mirror_out: .word 0x00000000

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
