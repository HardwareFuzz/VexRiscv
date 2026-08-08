package vexriscv

import vexriscv.plugin._
import spinal.core._

import scala.collection.mutable.ArrayBuffer
import scala.collection.Seq

object VexRiscvConfig{
  def apply(withMemoryStage : Boolean, withWriteBackStage : Boolean, plugins : Seq[Plugin[VexRiscv]]): VexRiscvConfig = {
    val config = VexRiscvConfig()
    config.plugins ++= plugins
    config.withMemoryStage = withMemoryStage
    config.withWriteBackStage = withWriteBackStage
    config
  }

  def apply(plugins : Seq[Plugin[VexRiscv]] = ArrayBuffer()) : VexRiscvConfig = apply(true,true,plugins)
}
trait VexRiscvRegressionArg{
  def getVexRiscvRegressionArgs() : Seq[String]
}
case class VexRiscvConfig(){
  var withMemoryStage = true
  var withWriteBackStage = true
  val plugins = ArrayBuffer[Plugin[VexRiscv]]()

  def add(that : Plugin[VexRiscv]) : this.type = {plugins += that;this}
  def find[T](clazz: Class[T]): Option[T] = {
    plugins.find(_.getClass == clazz) match {
      case Some(x) => Some(x.asInstanceOf[T])
      case None => None
    }
  }
  def get[T](clazz: Class[T]): T = {
    plugins.find(_.getClass == clazz) match {
      case Some(x) => x.asInstanceOf[T]
    }
  }

  def withRvc = plugins.find(_.isInstanceOf[IBusFetcher]) match {
    case Some(x) => x.asInstanceOf[IBusFetcher].withRvc
    case None => false
  }

  def withRvf = find(classOf[FpuPlugin]) match {
    case Some(x) => true
    case None => false
  }

  def withRvd = find(classOf[FpuPlugin]) match {
    case Some(x) => x.p.withDouble
    case None => false
  }

  def withSupervisor = find(classOf[CsrPlugin]) match {
    case Some(x) => x.config.supervisorGen
    case None => false
  }

  def FLEN = if(withRvd) 64 else if(withRvf) 32 else 0

  //Default Stageables
  object IS_RVC extends Stageable(Bool)
  object BYPASSABLE_EXECUTE_STAGE   extends Stageable(Bool)
  object BYPASSABLE_MEMORY_STAGE   extends Stageable(Bool)
  object RS1   extends Stageable(Bits(32 bits))
  object RS2   extends Stageable(Bits(32 bits))
  object RS1_USE extends Stageable(Bool)
  object RS2_USE extends Stageable(Bool)
  object RESULT extends Stageable(UInt(32 bits))
  object PC extends Stageable(UInt(32 bits))
  object PC_CALC_WITHOUT_JUMP extends Stageable(UInt(32 bits))
  object INSTRUCTION extends Stageable(Bits(32 bits))
  object INSTRUCTION_ANTICIPATED extends Stageable(Bits(32 bits))
  object LEGAL_INSTRUCTION extends Stageable(Bool)
  object REGFILE_WRITE_VALID extends Stageable(Bool)
  object REGFILE_WRITE_DATA extends Stageable(Bits(32 bits))
  // CX trace v2 metadata.  These values are allocated once when the decode
  // instruction is accepted and are then carried by the normal pipeline
  // registers.  LOG_TOKEN is unique within one hart (VexRiscv instance).
  object LOG_START_CYCLE extends Stageable(UInt(64 bits))
  object LOG_TOKEN extends Stageable(UInt(64 bits))

  object MPP extends PipelineThing[UInt]
  object DEBUG_BYPASS_CACHE extends PipelineThing[Bool]

  object SRC1   extends Stageable(Bits(32 bits))
  object SRC2   extends Stageable(Bits(32 bits))
  object SRC_ADD_SUB extends Stageable(Bits(32 bits))
  object SRC_ADD extends Stageable(Bits(32 bits))
  object SRC_SUB extends Stageable(Bits(32 bits))
  object SRC_LESS extends Stageable(Bool)
  object SRC_USE_SUB_LESS extends Stageable(Bool)
  object SRC_LESS_UNSIGNED extends Stageable(Bool)
  object SRC_ADD_ZERO extends Stageable(Bool)


  object HAS_SIDE_EFFECT extends Stageable(Bool)

  //Formal verification purposes
  object FORMAL_HALT       extends Stageable(Bool)
  object FORMAL_PC_NEXT    extends Stageable(UInt(32 bits))
  object FORMAL_MEM_ADDR   extends Stageable(UInt(32 bits))
  object FORMAL_MEM_RMASK  extends Stageable(Bits(4 bits))
  object FORMAL_MEM_WMASK  extends Stageable(Bits(4 bits))
  object FORMAL_MEM_RDATA  extends Stageable(Bits(32 bits))
  object FORMAL_MEM_WDATA  extends Stageable(Bits(32 bits))
  object FORMAL_INSTRUCTION extends Stageable(Bits(32 bits))
  object FORMAL_MODE       extends Stageable(Bits(2 bits))


  object Src1CtrlEnum extends SpinalEnum(binarySequential){
    val RS, IMU, PC_INCREMENT, URS1 = newElement()   //IMU, IMZ IMJB
  }

  object Src2CtrlEnum extends SpinalEnum(binarySequential){
    val RS, IMI, IMS, PC = newElement() //TODO remplacing ZERO could avoid 32 muxes if SRC_ADD can be disabled
  }
  object SRC1_CTRL  extends Stageable(Src1CtrlEnum())
  object SRC2_CTRL  extends Stageable(Src2CtrlEnum())

  def getRegressionArgs() : Seq[String] = {
    val str = ArrayBuffer[String]()
    plugins.foreach{
      case e : VexRiscvRegressionArg => str ++= e.getVexRiscvRegressionArgs()
      case _ =>
    }
    str
  }
}




class VexRiscv(val config : VexRiscvConfig) extends Component with Pipeline{
  type  T = VexRiscv
  import config._

  //Define stages
  def newStage(): Stage = { val s = new Stage; stages += s; s }
  val decode    = newStage()
  val execute   = newStage()
  val memory    = ifGen(config.withMemoryStage)    (newStage())
  val writeBack = ifGen(config.withWriteBackStage) (newStage())
  val simCycle = Reg(UInt(64 bits)) init(0)
  val nextTraceToken = Reg(UInt(64 bits)) init(0)
  // A cache/MMU redo redirects the PC back to an instruction that has already
  // been accepted by decode.  Keep that instruction's original allocation
  // metadata outside the flushed pipeline so every retry remains one dynamic
  // architectural instruction in CXTRACE.
  val replayTraceValid = Reg(Bool) init(False)
  val replayTracePc = Reg(UInt(32 bits)) init(0)
  val replayTraceInstruction = Reg(Bits(32 bits)) init(0)
  val replayTraceStartCycle = Reg(UInt(64 bits)) init(0)
  val replayTraceToken = Reg(UInt(64 bits)) init(0)
  // CsrPlugin asserts this only on the cycle in which a synchronous decode
  // exception is accepted. Such an entry terminates precisely without ever
  // firing into execute, but it still needs to consume the token exposed on
  // the decode sidecar.
  val decodeTraceExceptionAlloc = False

  def stagesFromExecute = stages.dropWhile(_ != execute)

  plugins ++= config.plugins
  simCycle := simCycle + 1
  // simCycle is zero while reset is asserted, so the value sampled by a
  // decode allocation on the first post-reset rising edge is exactly one.
  val decodeTraceReplayMatch = replayTraceValid &&
    decode.input(config.PC) === replayTracePc &&
    decode.input(config.FORMAL_INSTRUCTION) === replayTraceInstruction
  decode.insert(config.LOG_START_CYCLE) := decodeTraceReplayMatch ? replayTraceStartCycle | (simCycle + 1)
  decode.insert(config.LOG_TOKEN) := decodeTraceReplayMatch ? replayTraceToken | nextTraceToken
  // Normal instructions allocate only when decode formally enters execute.
  // A synchronous exception detected in decode is the one exception: the CSR
  // exception controller accepts it as an architectural terminal directly,
  // so its exact acceptance pulse must consume the token as well. Branch
  // flushes and ordinary stalls do neither.
  val decodeTraceAlloc = decode.arbitration.isFiring || decodeTraceExceptionAlloc
  when(decodeTraceAlloc) {
    when(decodeTraceReplayMatch) {
      replayTraceValid := False
    } otherwise {
      nextTraceToken := nextTraceToken + 1
    }
  }

  //regression usage
  val traceCycle = CombInit(simCycle).dontSimplifyIt().setName("traceCycle").addAttribute(Verilator.public)
  val decodeTraceIsAllocating = CombInit(decodeTraceAlloc).dontSimplifyIt().setName("decodeTraceIsAllocating").addAttribute(Verilator.public)
  val decodeTraceIsReusingReplay = CombInit(decodeTraceAlloc && decodeTraceReplayMatch).dontSimplifyIt().setName("decodeTraceIsReusingReplay").addAttribute(Verilator.public)
  val executePc = CombInit(execute.input(config.PC)).dontSimplifyIt().setName("executePc").addAttribute(Verilator.public)
  val executeIsFiring = CombInit(execute.arbitration.isFiring).dontSimplifyIt().setName("executeIsFiring").addAttribute(Verilator.public)
  val memoryStagePc = CombInit(if(config.withMemoryStage) memory.input(config.PC) else execute.input(config.PC)).dontSimplifyIt().setName("memoryStagePc").addAttribute(Verilator.public)
  val memoryStageStartCycle = CombInit(if(config.withMemoryStage) memory.input(config.LOG_START_CYCLE) else execute.input(config.LOG_START_CYCLE)).dontSimplifyIt().setName("memoryStageStartCycle").addAttribute(Verilator.public)
  val memoryStageToken = CombInit(if(config.withMemoryStage) memory.input(config.LOG_TOKEN) else execute.input(config.LOG_TOKEN)).dontSimplifyIt().setName("memoryStageToken").addAttribute(Verilator.public)
  val lastStageInstruction = CombInit(stages.last.input(config.INSTRUCTION)).dontSimplifyIt().addAttribute (Verilator.public)
  val lastStageRawInstruction = CombInit(stages.last.input(config.FORMAL_INSTRUCTION)).dontSimplifyIt().setName("lastStageRawInstruction").addAttribute(Verilator.public)
  val lastStageIsRvc = CombInit(if(config.withRvc) stages.last.input(config.IS_RVC) else False).dontSimplifyIt().setName("lastStageIsRvc").addAttribute(Verilator.public)
  val lastStagePc = CombInit(stages.last.input(config.PC)).dontSimplifyIt().addAttribute(Verilator.public)
  val lastStageStartCycle = CombInit(stages.last.input(config.LOG_START_CYCLE)).dontSimplifyIt().setName("lastStageStartCycle").addAttribute(Verilator.public)
  val lastStageToken = CombInit(stages.last.input(config.LOG_TOKEN)).dontSimplifyIt().setName("lastStageToken").addAttribute(Verilator.public)
  val lastStageIsValid = CombInit(stages.last.arbitration.isValid).dontSimplifyIt().addAttribute(Verilator.public)
  val lastStageIsFiring = CombInit(stages.last.arbitration.isFiring).dontSimplifyIt().addAttribute(Verilator.public)

  // A committed instruction must always carry metadata sampled at allocation.
  // These assertions are simulation-visible and catch accidental zero/default
  // metadata or a future cycle-domain regression immediately.
  when(stages.last.arbitration.isFiring) {
    assert(stages.last.input(config.LOG_START_CYCLE) =/= 0)
    assert(stages.last.input(config.LOG_START_CYCLE) <= simCycle)
  }

  //Verilator perf
  decode.arbitration.removeIt.noBackendCombMerge
  if(withMemoryStage){
    memory.arbitration.removeIt.noBackendCombMerge
  }
  execute.arbitration.flushNext.noBackendCombMerge
}
