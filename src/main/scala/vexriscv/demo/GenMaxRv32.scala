package vexriscv.demo

import vexriscv.plugin._
import vexriscv.ip.{DataCacheConfig, InstructionCacheConfig}
import vexriscv.{plugin, VexRiscv, VexRiscvConfig}
import spinal.core._

/**
  * RV32 "max" configuration without FPU (RV32IMA + S-mode, MMU, LR/SC, AMO, RVC).
  * Kept close to GenMax/GenMaxRv32F so the Verilator harness build flags stay consistent.
  */
object GenMaxRv32 extends App {
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
        compressedGen = true,
        memoryTranslatorPortConfig = MmuPortConfig(
          portTlbSize = 4
        ),
        injectorStage = true
      ),
      new DBusCachedPlugin(
        config = new DataCacheConfig(
          cacheSize = 4096,
          bytePerLine = 32,
          wayCount = 1,
          addressWidth = 32,
          cpuDataWidth = 64,
          memDataWidth = 64,
          catchAccessError = true,
          catchIllegal = true,
          catchUnaligned = true,
          withLrSc = true,
          withAmo = true
        ),
        memoryTranslatorPortConfig = MmuPortConfig(
          portTlbSize = 6
        )
      ),
      new MmuPlugin(
        virtualRange = _(31 downto 28) === 0xC,
        ioRange = _(31 downto 28) === 0xF
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
        bypassExecute = true,
        bypassMemory = true,
        bypassWriteBack = true,
        bypassWriteBackBuffer = true,
        pessimisticUseSrc = false,
        pessimisticWriteRegFile = false,
        pessimisticAddressMatch = false
      ),
      new MulPlugin,
      new DivPlugin,
      new CsrPlugin(CsrPluginConfig.linuxFull(0x80000020l)),
      new DebugPlugin(ClockDomain.current.clone(reset = Bool().setName("debugReset"))),
      new BranchPlugin(
        earlyBranch = false,
        catchAddressMisaligned = true
      ),
      new YamlPlugin("cpu0_rv32.yaml")
    )
  )

  def cpu() = new VexRiscv(config)

  SpinalVerilog(cpu())
}
