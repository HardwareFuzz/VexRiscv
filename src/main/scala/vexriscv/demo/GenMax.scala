package vexriscv.demo

import vexriscv.plugin._
import vexriscv.ip.{DataCacheConfig, InstructionCacheConfig}
import vexriscv.ip.fpu.FpuParameter
import vexriscv.{plugin, VexRiscv, VexRiscvConfig}
import spinal.core._

/**
  * RV32 core with "max" feature set aiming at IMAFDC + S-mode, MMU, LR/SC and AMO.
  * This augments the GenFull baseline by:
  *  - Enabling compressed instructions on IBus
  *  - Enabling LR/SC and AMO in DCache
  *  - Adding FPU with double-precision support (RVF+RVD)
  *  - Using a Linux-friendly CSR configuration (user+supervisor)
  */
object GenMax extends App {
  def config = VexRiscvConfig(
    plugins = List(
      new IBusCachedPlugin(
        prediction = DYNAMIC,
        config = InstructionCacheConfig(
          cacheSize = 4096,
          bytePerLine = 32,
          wayCount = 1,
          addressWidth = 32,
          cpuDataWidth = 32,
          memDataWidth = 64,
          catchIllegalAccess = true,
          catchAccessFault = true,
          asyncTagMemory = false,
          twoCycleRam = true,
          twoCycleCache = true
        ),
        compressedGen = true, // Enable RVC
        memoryTranslatorPortConfig = MmuPortConfig(
          portTlbSize = 4
        ),
        injectorStage = true
      ),
      new DBusCachedPlugin(
        config = new DataCacheConfig(
          cacheSize         = 4096,
          bytePerLine       = 32,
          wayCount          = 1,
          addressWidth      = 32,
          cpuDataWidth      = 64,
          memDataWidth      = 64,
          catchAccessError  = true,
          catchIllegal      = true,
          catchUnaligned    = true,
          withLrSc          = true,  // Enable LR/SC
          withAmo           = true   // Enable AMO
        ),
        memoryTranslatorPortConfig = MmuPortConfig(
          portTlbSize = 6
        )
      ),
      new MmuPlugin(
        virtualRange = _(31 downto 28) === 0xC,
        ioRange      = _(31 downto 28) === 0xF
      ),
      new DecoderSimplePlugin(
        catchIllegalInstruction = true
      ),
      new RegFilePlugin(
        regFileReadyKind = plugin.SYNC,
        zeroBoot = false
      ),
      new IntAluPlugin,
      new SrcPlugin(
        separatedAddSub = false,
        executeInsertion = true
      ),
      new FullBarrelShifterPlugin,
      new HazardSimplePlugin(
        bypassExecute           = true,
        bypassMemory            = true,
        bypassWriteBack         = true,
        bypassWriteBackBuffer   = true,
        pessimisticUseSrc       = false,
        pessimisticWriteRegFile = false,
        pessimisticAddressMatch = false
      ),
      new MulPlugin,
      new DivPlugin,
      new FpuPlugin(simHalt = true, p = FpuParameter(withDouble = true)), // RVF + RVD
      new CsrPlugin(CsrPluginConfig.linuxFull(0x80000020l)),
      new DebugPlugin(ClockDomain.current.clone(reset = Bool().setName("debugReset"))),
      new BranchPlugin(
        earlyBranch = false,
        catchAddressMisaligned = true
      ),
      new YamlPlugin("cpu0.yaml")
    )
  )

  def cpu() = new VexRiscv(config)

  SpinalVerilog(cpu())
}
