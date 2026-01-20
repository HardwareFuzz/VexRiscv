package vexriscv.demo

import vexriscv.ip.{DataCacheConfig, InstructionCacheConfig}
import vexriscv.plugin._
import vexriscv.{plugin, VexRiscv, VexRiscvConfig}
import spinal.core._

object GenMemOrder extends App {
  sealed trait Variant {
    def name: String
    def withWriteAggregation: Boolean
    def withFence: Boolean
    def withAtomic: Boolean
  }

  object Variant {
    case object Cache extends Variant {
      val name = "cache"
      val withWriteAggregation = false
      val withFence = false
      val withAtomic = false
    }
    case object StoreBuffer extends Variant {
      val name = "store-buffer"
      val withWriteAggregation = true
      val withFence = false
      val withAtomic = false
    }
    case object Fence extends Variant {
      val name = "fence"
      val withWriteAggregation = true
      val withFence = true
      val withAtomic = false
    }
    case object Atomic extends Variant {
      val name = "atomic"
      val withWriteAggregation = true
      val withFence = true
      val withAtomic = true
    }

    val all = Seq(Cache, StoreBuffer, Fence, Atomic)

    private val aliases = Map(
      "cache" -> Cache,
      "cached" -> Cache,
      "store-buffer" -> StoreBuffer,
      "store_buffer" -> StoreBuffer,
      "storebuffer" -> StoreBuffer,
      "sb" -> StoreBuffer,
      "fence" -> Fence,
      "atomic" -> Atomic,
      "amo" -> Atomic
    )

    def parse(name: String): Variant = {
      aliases.getOrElse(name.toLowerCase, {
        System.err.println(s"Unknown memorder variant: ${name}")
        System.err.println(s"Valid variants: ${all.map(_.name).mkString(", ")}")
        sys.exit(1)
        Cache
      })
    }
  }

  private def usageAndExit(exitCode: Int): Unit = {
    System.out.println("Usage: GenMemOrder <cache|store-buffer|fence|atomic>")
    sys.exit(exitCode)
  }

  private def selectVariant(args: Array[String]): Variant = {
    if (args.contains("--help") || args.contains("-h")) usageAndExit(0)

    val it = args.iterator
    var nameOpt: Option[String] = None
    while (it.hasNext) {
      it.next() match {
        case "--variant" | "-v" =>
          if (!it.hasNext) usageAndExit(1)
          nameOpt = Some(it.next())
        case arg if !arg.startsWith("-") && nameOpt.isEmpty =>
          nameOpt = Some(arg)
        case _ =>
      }
    }

    nameOpt.map(Variant.parse).getOrElse {
      System.out.println("[info] GenMemOrder: defaulting to cache variant")
      Variant.Cache
    }
  }

  private def configFor(variant: Variant) = VexRiscvConfig(
    plugins = List(
      new IBusCachedPlugin(
        prediction = STATIC,
        config = InstructionCacheConfig(
          cacheSize = 4096,
          bytePerLine = 32,
          wayCount = 1,
          addressWidth = 32,
          cpuDataWidth = 32,
          memDataWidth = 32,
          catchIllegalAccess = true,
          catchAccessFault = true,
          asyncTagMemory = false,
          twoCycleRam = true,
          twoCycleCache = true
        )
      ),
      new DBusCachedPlugin(
        dBusRspSlavePipe = variant.withAtomic,
        config = DataCacheConfig(
          cacheSize = 4096,
          bytePerLine = 32,
          wayCount = 1,
          addressWidth = 32,
          cpuDataWidth = 32,
          memDataWidth = 32,
          catchAccessError = true,
          catchIllegal = true,
          catchUnaligned = true,
          withExclusive = variant.withAtomic,
          withInvalidate = variant.withFence,
          withLrSc = variant.withAtomic,
          withAmo = variant.withAtomic,
          withWriteAggregation = variant.withWriteAggregation
        )
      ),
      new StaticMemoryTranslatorPlugin(
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
      new CsrPlugin(CsrPluginConfig.all(0x80000020l)),
      new ExternalInterruptArrayPlugin(2),
      new DebugPlugin(ClockDomain.current.clone(reset = Bool().setName("debugReset"))),
      new BranchPlugin(
        earlyBranch = false,
        catchAddressMisaligned = true
      ),
      new YamlPlugin("cpu0.yaml")
    )
  )

  val variant = selectVariant(args)
  SpinalVerilog(new VexRiscv(configFor(variant)))
}
