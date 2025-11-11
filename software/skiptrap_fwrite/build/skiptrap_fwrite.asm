
build/skiptrap_fwrite.elf:     file format elf32-littleriscv


Disassembly of section .text:

80000000 <_start>:
80000000:	00000297          	auipc	t0,0x0
80000004:	17c28293          	addi	t0,t0,380 # 8000017c <trap_handler>
80000008:	30529073          	csrw	mtvec,t0
8000000c:	300022f3          	csrr	t0,mstatus
80000010:	630d                	lui	t1,0x3
80000012:	0062e2b3          	or	t0,t0,t1
80000016:	30029073          	csrw	mstatus,t0
8000001a:	00301073          	fscsr	zero
8000001e:	a009                	j	80000020 <user_code>

80000020 <user_code>:
80000020:	00000397          	auipc	t2,0x0
80000024:	1d038393          	addi	t2,t2,464 # 800001f0 <f32_inputs>
80000028:	0003a007          	flw	ft0,0(t2)
8000002c:	0043a087          	flw	ft1,4(t2)
80000030:	0083a107          	flw	ft2,8(t2)
80000034:	00c3a187          	flw	ft3,12(t2)
80000038:	404002b7          	lui	t0,0x40400
8000003c:	f0028253          	fmv.w.x	ft4,t0
80000040:	000072d3          	fadd.s	ft5,ft0,ft0
80000044:	08017353          	fsub.s	ft6,ft2,ft0
80000048:	101073d3          	fmul.s	ft7,ft0,ft1
8000004c:	18017453          	fdiv.s	fs0,ft2,ft0
80000050:	580174d3          	fsqrt.s	fs1,ft2
80000054:	10107543          	fmadd.s	fa0,ft0,ft1,ft2
80000058:	180175c7          	fmsub.s	fa1,ft2,ft0,ft3
8000005c:	1030f64f          	fnmadd.s	fa2,ft1,ft3,ft2
80000060:	003176cb          	fnmsub.s	fa3,ft2,ft3,ft0
80000064:	20208753          	fsgnj.s	fa4,ft1,ft2
80000068:	202097d3          	fsgnjn.s	fa5,ft1,ft2
8000006c:	20102853          	fsgnjx.s	fa6,ft0,ft1
80000070:	281008d3          	fmin.s	fa7,ft0,ft1
80000074:	28201953          	fmax.s	fs2,ft0,ft2
80000078:	5365                	li	t1,-7
8000007a:	d00379d3          	fcvt.s.w	fs3,t1
8000007e:	4325                	li	t1,9
80000080:	d0137a53          	fcvt.s.wu	fs4,t1
80000084:	00000e17          	auipc	t3,0x0
80000088:	17ce0e13          	addi	t3,t3,380 # 80000200 <f64_inputs>
8000008c:	00000f97          	auipc	t6,0x0
80000090:	1d4f8f93          	addi	t6,t6,468 # 80000260 <f64_results>
80000094:	000e3b87          	fld	fs7,0(t3)
80000098:	008e3c07          	fld	fs8,8(t3)
8000009c:	010e3c87          	fld	fs9,16(t3)
800000a0:	401c7ad3          	fcvt.s.d	fs5,fs8
800000a4:	401cfb53          	fcvt.s.d	fs6,fs9
800000a8:	42028d53          	fcvt.d.s	fs10,ft5
800000ac:	01afb027          	fsd	fs10,0(t6)
800000b0:	5ed1                	li	t4,-12
800000b2:	d20e8dd3          	fcvt.d.w	fs11,t4
800000b6:	01bfb427          	fsd	fs11,8(t6)
800000ba:	4eb5                	li	t4,13
800000bc:	d21e8e53          	fcvt.d.wu	ft8,t4
800000c0:	01cfb827          	fsd	ft8,16(t6)
800000c4:	039bfed3          	fadd.d	ft9,fs7,fs9
800000c8:	01dfbc27          	fsd	ft9,24(t6)
800000cc:	0b8cfed3          	fsub.d	ft9,fs9,fs8
800000d0:	03dfb027          	fsd	ft9,32(t6)
800000d4:	138bfed3          	fmul.d	ft9,fs7,fs8
800000d8:	03dfb427          	fsd	ft9,40(t6)
800000dc:	1b7cfed3          	fdiv.d	ft9,fs9,fs7
800000e0:	03dfb827          	fsd	ft9,48(t6)
800000e4:	5a0cfed3          	fsqrt.d	ft9,fs9
800000e8:	03dfbc27          	fsd	ft9,56(t6)
800000ec:	c39bfec3          	fmadd.d	ft9,fs7,fs9,fs8
800000f0:	05dfb027          	fsd	ft9,64(t6)
800000f4:	c37cfec7          	fmsub.d	ft9,fs9,fs7,fs8
800000f8:	05dfb427          	fsd	ft9,72(t6)
800000fc:	cb7c7ecf          	fnmadd.d	ft9,fs8,fs7,fs9
80000100:	05dfb827          	fsd	ft9,80(t6)
80000104:	bb8cfecb          	fnmsub.d	ft9,fs9,fs8,fs7
80000108:	05dfbc27          	fsd	ft9,88(t6)
8000010c:	42048ed3          	fcvt.d.s	ft9,fs1
80000110:	07dfb027          	fsd	ft9,96(t6)
80000114:	00000f17          	auipc	t5,0x0
80000118:	104f0f13          	addi	t5,t5,260 # 80000218 <f32_results>
8000011c:	005f2027          	fsw	ft5,0(t5)
80000120:	006f2227          	fsw	ft6,4(t5)
80000124:	007f2427          	fsw	ft7,8(t5)
80000128:	008f2627          	fsw	fs0,12(t5)
8000012c:	009f2827          	fsw	fs1,16(t5)
80000130:	00af2a27          	fsw	fa0,20(t5)
80000134:	00bf2c27          	fsw	fa1,24(t5)
80000138:	00cf2e27          	fsw	fa2,28(t5)
8000013c:	02df2027          	fsw	fa3,32(t5)
80000140:	02ef2227          	fsw	fa4,36(t5)
80000144:	02ff2427          	fsw	fa5,40(t5)
80000148:	030f2627          	fsw	fa6,44(t5)
8000014c:	031f2827          	fsw	fa7,48(t5)
80000150:	032f2a27          	fsw	fs2,52(t5)
80000154:	033f2c27          	fsw	fs3,56(t5)
80000158:	034f2e27          	fsw	fs4,60(t5)
8000015c:	055f2027          	fsw	fs5,64(t5)
80000160:	056f2227          	fsw	fs6,68(t5)
80000164:	00000073          	ecall
80000168:	ffffffff          	.word	0xffffffff

8000016c <exit>:
8000016c:	4281                	li	t0,0
8000016e:	70100317          	auipc	t1,0x70100
80000172:	db230313          	addi	t1,t1,-590 # f00fff20 <tohost>
80000176:	00532023          	sw	t0,0(t1)
8000017a:	a001                	j	8000017a <exit+0xe>

8000017c <trap_handler>:
8000017c:	341022f3          	csrr	t0,mepc
80000180:	34202373          	csrr	t1,mcause
80000184:	34302ef3          	csrr	t4,mtval
80000188:	00131f13          	slli	t5,t1,0x1
8000018c:	001f5313          	srli	t1,t5,0x1
80000190:	4389                	li	t2,2
80000192:	4e09                	li	t3,2
80000194:	01c30a63          	beq	t1,t3,800001a8 <decode_length>
80000198:	4e05                	li	t3,1
8000019a:	01c30563          	beq	t1,t3,800001a4 <read_mem_half>
8000019e:	4e31                	li	t3,12
800001a0:	01c30263          	beq	t1,t3,800001a4 <read_mem_half>

800001a4 <read_mem_half>:
800001a4:	0002de83          	lhu	t4,0(t0) # 40400000 <_start-0x3fc00000>

800001a8 <decode_length>:
800001a8:	003efe93          	andi	t4,t4,3
800001ac:	4e0d                	li	t3,3
800001ae:	01ce9463          	bne	t4,t3,800001b6 <compressed_len>
800001b2:	4391                	li	t2,4
800001b4:	a011                	j	800001b8 <update_mepc>

800001b6 <compressed_len>:
800001b6:	4389                	li	t2,2

800001b8 <update_mepc>:
800001b8:	929e                	add	t0,t0,t2
800001ba:	34129073          	csrw	mepc,t0
800001be:	34201073          	csrw	mcause,zero
800001c2:	34301073          	csrw	mtval,zero
800001c6:	30200073          	mret

800001ca <fail_code_0xE1>:
800001ca:	f01003b7          	lui	t2,0xf0100
800001ce:	f2438393          	addi	t2,t2,-220 # f00fff24 <fromhost>
800001d2:	0e100293          	li	t0,225
800001d6:	0053a023          	sw	t0,0(t2)
800001da:	a001                	j	800001da <fail_code_0xE1+0x10>

800001dc <fail_code_0xE2>:
800001dc:	f01003b7          	lui	t2,0xf0100
800001e0:	f2438393          	addi	t2,t2,-220 # f00fff24 <fromhost>
800001e4:	0e200293          	li	t0,226
800001e8:	0053a023          	sw	t0,0(t2)
800001ec:	a001                	j	800001ec <fail_code_0xE2+0x10>
