
build/skiptrap.elf:     file format elf32-littleriscv


Disassembly of section .text:

80000000 <_start>:
80000000:	00000297          	auipc	t0,0x0
80000004:	2e828293          	addi	t0,t0,744 # 800002e8 <trap_handler>
80000008:	30529073          	csrw	mtvec,t0
8000000c:	300022f3          	csrr	t0,mstatus
80000010:	630d                	lui	t1,0x3
80000012:	0062e2b3          	or	t0,t0,t1
80000016:	30029073          	csrw	mstatus,t0
8000001a:	00301073          	fscsr	zero
8000001e:	a009                	j	80000020 <user_code>

80000020 <user_code>:
80000020:	12345437          	lui	s0,0x12345
80000024:	67840413          	addi	s0,s0,1656 # 12345678 <_start-0x6dcba988>
80000028:	89abd4b7          	lui	s1,0x89abd
8000002c:	def48493          	addi	s1,s1,-529 # 89abcdef <__bss_end+0x9abc9bf>
80000030:	00940933          	add	s2,s0,s1
80000034:	00000397          	auipc	t2,0x0
80000038:	32c38393          	addi	t2,t2,812 # 80000360 <buf>
8000003c:	0083a023          	sw	s0,0(t2)
80000040:	0003ae03          	lw	t3,0(t2)
80000044:	00000073          	ecall
80000048:	0013ae83          	lw	t4,1(t2)
8000004c:	ffffffff          	.word	0xffffffff
80000050:	00000397          	auipc	t2,0x0
80000054:	31838393          	addi	t2,t2,792 # 80000368 <buf_byte>
80000058:	00838023          	sb	s0,0(t2)
8000005c:	00000397          	auipc	t2,0x0
80000060:	31038393          	addi	t2,t2,784 # 8000036c <buf_half>
80000064:	00839023          	sh	s0,0(t2)
80000068:	0badc9b7          	lui	s3,0xbadc
8000006c:	0de98993          	addi	s3,s3,222 # badc0de <_start-0x74523f22>
80000070:	1357aa37          	lui	s4,0x1357a
80000074:	bdfa0a13          	addi	s4,s4,-1057 # 13579bdf <_start-0x6ca86421>
80000078:	00000397          	auipc	t2,0x0
8000007c:	2ec38393          	addi	t2,t2,748 # 80000364 <buf2>
80000080:	0143a023          	sw	s4,0(t2)
80000084:	0003ae03          	lw	t3,0(t2)
80000088:	00000517          	auipc	a0,0x0
8000008c:	2e850513          	addi	a0,a0,744 # 80000370 <amo1>
80000090:	112235b7          	lui	a1,0x11223
80000094:	34458593          	addi	a1,a1,836 # 11223344 <_start-0x6eddccbc>
80000098:	08b52aaf          	amoswap.w	s5,a1,(a0)
8000009c:	00000517          	auipc	a0,0x0
800000a0:	2d850513          	addi	a0,a0,728 # 80000374 <amo2>
800000a4:	4595                	li	a1,5
800000a6:	00b52aaf          	amoadd.w	s5,a1,(a0)
800000aa:	00000517          	auipc	a0,0x0
800000ae:	2ce50513          	addi	a0,a0,718 # 80000378 <amo3>
800000b2:	65bd                	lui	a1,0xf
800000b4:	0f058593          	addi	a1,a1,240 # f0f0 <_start-0x7fff0f10>
800000b8:	40b52aaf          	amoor.w	s5,a1,(a0)
800000bc:	00000517          	auipc	a0,0x0
800000c0:	2c050513          	addi	a0,a0,704 # 8000037c <amo4>
800000c4:	00ff05b7          	lui	a1,0xff0
800000c8:	0ff58593          	addi	a1,a1,255 # ff00ff <_start-0x7f00ff01>
800000cc:	60b52aaf          	amoand.w	s5,a1,(a0)
800000d0:	00000517          	auipc	a0,0x0
800000d4:	2b050513          	addi	a0,a0,688 # 80000380 <amo5>
800000d8:	4595                	li	a1,5
800000da:	80b52aaf          	amomin.w	s5,a1,(a0)
800000de:	00000517          	auipc	a0,0x0
800000e2:	2a650513          	addi	a0,a0,678 # 80000384 <amo6>
800000e6:	4595                	li	a1,5
800000e8:	a0b52aaf          	amomax.w	s5,a1,(a0)
800000ec:	00000397          	auipc	t2,0x0
800000f0:	29c38393          	addi	t2,t2,668 # 80000388 <f32_a>
800000f4:	0003a007          	flw	ft0,0(t2)
800000f8:	000070d3          	fadd.s	ft1,ft0,ft0
800000fc:	e0008fd3          	fmv.x.w	t6,ft1
80000100:	00000397          	auipc	t2,0x0
80000104:	28c38393          	addi	t2,t2,652 # 8000038c <f32_out>
80000108:	0013a027          	fsw	ft1,0(t2)
8000010c:	0800f153          	fsub.s	ft2,ft1,ft0
80000110:	00000397          	auipc	t2,0x0
80000114:	28038393          	addi	t2,t2,640 # 80000390 <f32_sub_out>
80000118:	0023a027          	fsw	ft2,0(t2)
8000011c:	100071d3          	fmul.s	ft3,ft0,ft0
80000120:	00000397          	auipc	t2,0x0
80000124:	27438393          	addi	t2,t2,628 # 80000394 <f32_mul_out>
80000128:	0033a027          	fsw	ft3,0(t2)
8000012c:	1800f253          	fdiv.s	ft4,ft1,ft0
80000130:	00000397          	auipc	t2,0x0
80000134:	26838393          	addi	t2,t2,616 # 80000398 <f32_div_out>
80000138:	0043a027          	fsw	ft4,0(t2)
8000013c:	c000ff53          	fcvt.w.s	t5,ft1
80000140:	00000397          	auipc	t2,0x0
80000144:	25c38393          	addi	t2,t2,604 # 8000039c <f32_i_out>
80000148:	01e3a023          	sw	t5,0(t2)
8000014c:	d00f72d3          	fcvt.s.w	ft5,t5
80000150:	00000397          	auipc	t2,0x0
80000154:	25038393          	addi	t2,t2,592 # 800003a0 <f32_cvt_back_out>
80000158:	0053a027          	fsw	ft5,0(t2)
8000015c:	20000353          	fmv.s	ft6,ft0
80000160:	00000397          	auipc	t2,0x0
80000164:	24438393          	addi	t2,t2,580 # 800003a4 <f32_sgnj_out>
80000168:	0063a027          	fsw	ft6,0(t2)
8000016c:	200013d3          	fneg.s	ft7,ft0
80000170:	00000397          	auipc	t2,0x0
80000174:	23838393          	addi	t2,t2,568 # 800003a8 <f32_sgnjn_out>
80000178:	0073a027          	fsw	ft7,0(t2)
8000017c:	20002453          	fabs.s	fs0,ft0
80000180:	00000397          	auipc	t2,0x0
80000184:	22c38393          	addi	t2,t2,556 # 800003ac <f32_sgnjx_out>
80000188:	0083a027          	fsw	fs0,0(t2)
8000018c:	281004d3          	fmin.s	fs1,ft0,ft1
80000190:	00000397          	auipc	t2,0x0
80000194:	22038393          	addi	t2,t2,544 # 800003b0 <f32_min_out>
80000198:	0093a027          	fsw	fs1,0(t2)
8000019c:	28101553          	fmax.s	fa0,ft0,ft1
800001a0:	00000397          	auipc	t2,0x0
800001a4:	21438393          	addi	t2,t2,532 # 800003b4 <f32_max_out>
800001a8:	00a3a027          	fsw	fa0,0(t2)
800001ac:	00007643          	fmadd.s	fa2,ft0,ft0,ft0
800001b0:	000076cb          	fnmsub.s	fa3,ft0,ft0,ft0
800001b4:	0000f743          	fmadd.s	fa4,ft1,ft0,ft0
800001b8:	0000f7c7          	fmsub.s	fa5,ft1,ft0,ft0
800001bc:	c010ffd3          	fcvt.wu.s	t6,ft1
800001c0:	00000397          	auipc	t2,0x0
800001c4:	1f838393          	addi	t2,t2,504 # 800003b8 <f32_iwu_out>
800001c8:	01f3a023          	sw	t6,0(t2)
800001cc:	d01ff853          	fcvt.s.wu	fa6,t6
800001d0:	00000397          	auipc	t2,0x0
800001d4:	1ec38393          	addi	t2,t2,492 # 800003bc <f32_wu_back_out>
800001d8:	0103a027          	fsw	fa6,0(t2)
800001dc:	a00022d3          	feq.s	t0,ft0,ft0
800001e0:	00000397          	auipc	t2,0x0
800001e4:	1e038393          	addi	t2,t2,480 # 800003c0 <f32_feq_out>
800001e8:	0053a023          	sw	t0,0(t2)
800001ec:	a0101353          	flt.s	t1,ft0,ft1
800001f0:	00000397          	auipc	t2,0x0
800001f4:	1d438393          	addi	t2,t2,468 # 800003c4 <f32_flt_out>
800001f8:	0063a023          	sw	t1,0(t2)
800001fc:	a01003d3          	fle.s	t2,ft0,ft1
80000200:	00000e17          	auipc	t3,0x0
80000204:	1c8e0e13          	addi	t3,t3,456 # 800003c8 <f32_fle_out>
80000208:	007e2023          	sw	t2,0(t3)
8000020c:	e0001e53          	fclass.s	t3,ft0
80000210:	00000e97          	auipc	t4,0x0
80000214:	1bce8e93          	addi	t4,t4,444 # 800003cc <f32_fclass_out>
80000218:	01cea023          	sw	t3,0(t4)
8000021c:	00000397          	auipc	t2,0x0
80000220:	1b438393          	addi	t2,t2,436 # 800003d0 <f64_a>
80000224:	0003b107          	fld	ft2,0(t2)
80000228:	022171d3          	fadd.d	ft3,ft2,ft2
8000022c:	00000397          	auipc	t2,0x0
80000230:	1ac38393          	addi	t2,t2,428 # 800003d8 <f64_out>
80000234:	0033b027          	fsd	ft3,0(t2)
80000238:	c201fe53          	fcvt.w.d	t3,ft3
8000023c:	00000397          	auipc	t2,0x0
80000240:	1a438393          	addi	t2,t2,420 # 800003e0 <f64_i_out>
80000244:	01c3a023          	sw	t3,0(t2)
80000248:	d20e0253          	fcvt.d.w	ft4,t3
8000024c:	00000397          	auipc	t2,0x0
80000250:	19c38393          	addi	t2,t2,412 # 800003e8 <f64_cvt_back_out>
80000254:	0043b027          	fsd	ft4,0(t2)
80000258:	12217953          	fmul.d	fs2,ft2,ft2
8000025c:	122179c3          	fmadd.d	fs3,ft2,ft2,ft2
80000260:	1221fa47          	fmsub.d	fs4,ft3,ft2,ft2
80000264:	0a21fad3          	fsub.d	fs5,ft3,ft2
80000268:	00000397          	auipc	t2,0x0
8000026c:	18838393          	addi	t2,t2,392 # 800003f0 <f32_fnmadd_src>
80000270:	0003a907          	flw	fs2,0(t2)
80000274:	0043aa07          	flw	fs4,4(t2)
80000278:	0083ab87          	flw	fs7,8(t2)
8000027c:	00c3ab07          	flw	fs6,12(t2)
80000280:	b9497b4f          	fnmadd.s	fs6,fs2,fs4,fs7
80000284:	00000397          	auipc	t2,0x0
80000288:	17c38393          	addi	t2,t2,380 # 80000400 <f32_fnmadd_out>
8000028c:	0163a027          	fsw	fs6,0(t2)
80000290:	00000397          	auipc	t2,0x0
80000294:	17838393          	addi	t2,t2,376 # 80000408 <f64_fmax_src>
80000298:	0003b907          	fld	fs2,0(t2)
8000029c:	0083ba07          	fld	fs4,8(t2)
800002a0:	0103b987          	fld	fs3,16(t2)
800002a4:	2b4919d3          	fmax.d	fs3,fs2,fs4
800002a8:	00000397          	auipc	t2,0x0
800002ac:	17838393          	addi	t2,t2,376 # 80000420 <f64_fmax_out>
800002b0:	0133b027          	fsd	fs3,0(t2)
800002b4:	3f800337          	lui	t1,0x3f800
800002b8:	f00305d3          	fmv.w.x	fa1,t1
800002bc:	00000397          	auipc	t2,0x0
800002c0:	16c38393          	addi	t2,t2,364 # 80000428 <f32_from_x_out>
800002c4:	00b3a027          	fsw	fa1,0(t2)
800002c8:	e0058fd3          	fmv.x.w	t6,fa1
800002cc:	00000397          	auipc	t2,0x0
800002d0:	16038393          	addi	t2,t2,352 # 8000042c <f32_from_x_mirror_out>
800002d4:	01f3a023          	sw	t6,0(t2)

800002d8 <exit>:
800002d8:	4281                	li	t0,0
800002da:	70100317          	auipc	t1,0x70100
800002de:	c4630313          	addi	t1,t1,-954 # f00fff20 <tohost>
800002e2:	00532023          	sw	t0,0(t1)
800002e6:	a001                	j	800002e6 <exit+0xe>

800002e8 <trap_handler>:
800002e8:	341022f3          	csrr	t0,mepc
800002ec:	34202373          	csrr	t1,mcause
800002f0:	34302ef3          	csrr	t4,mtval
800002f4:	00131f13          	slli	t5,t1,0x1
800002f8:	001f5313          	srli	t1,t5,0x1
800002fc:	4389                	li	t2,2
800002fe:	4e09                	li	t3,2
80000300:	01c30a63          	beq	t1,t3,80000314 <decode_length>
80000304:	4e05                	li	t3,1
80000306:	01c30563          	beq	t1,t3,80000310 <read_mem_half>
8000030a:	4e31                	li	t3,12
8000030c:	01c30263          	beq	t1,t3,80000310 <read_mem_half>

80000310 <read_mem_half>:
80000310:	0002de83          	lhu	t4,0(t0)

80000314 <decode_length>:
80000314:	003efe93          	andi	t4,t4,3
80000318:	4e0d                	li	t3,3
8000031a:	01ce9463          	bne	t4,t3,80000322 <compressed_len>
8000031e:	4391                	li	t2,4
80000320:	a011                	j	80000324 <update_mepc>

80000322 <compressed_len>:
80000322:	4389                	li	t2,2

80000324 <update_mepc>:
80000324:	929e                	add	t0,t0,t2
80000326:	34129073          	csrw	mepc,t0
8000032a:	34201073          	csrw	mcause,zero
8000032e:	34301073          	csrw	mtval,zero
80000332:	30200073          	mret

80000336 <fail_code_0xE1>:
80000336:	f01003b7          	lui	t2,0xf0100
8000033a:	f2438393          	addi	t2,t2,-220 # f00fff24 <fromhost>
8000033e:	0e100293          	li	t0,225
80000342:	0053a023          	sw	t0,0(t2)
80000346:	a001                	j	80000346 <fail_code_0xE1+0x10>

80000348 <fail_code_0xE2>:
80000348:	f01003b7          	lui	t2,0xf0100
8000034c:	f2438393          	addi	t2,t2,-220 # f00fff24 <fromhost>
80000350:	0e200293          	li	t0,226
80000354:	0053a023          	sw	t0,0(t2)
80000358:	a001                	j	80000358 <fail_code_0xE2+0x10>
