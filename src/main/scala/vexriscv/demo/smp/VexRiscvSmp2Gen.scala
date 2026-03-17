package vexriscv.demo.smp

// Generate a 2-core SMP cluster netlist named VexRiscv in the repo root.
object VexRiscvSmp2Gen extends App {
  VexRiscvLitexSmpClusterCmdGen.main(Array(
    "--cpu-count", "2",
    "--netlist-name", "VexRiscv",
    "--netlist-directory", "."
  ))
}
