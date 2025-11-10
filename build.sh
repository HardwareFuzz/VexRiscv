#!/usr/bin/env bash
set -euo pipefail

# Build a Verilator-based VexRiscv simulator that accepts an ELF/HEX path.
# Output binary: build_result/genfull_rv32
#
# Requirements:
# - Java (for Scala codegen)
# - sbt (or network to fetch sbt-extras automatically)
# - Verilator (v4+ recommended, v5 tested)
# - A C++ toolchain (g++, make)
#
# Usage after build:
#   ./build_result/genfull_rv32 path/to/program.elf
#   ./build_result/genfull_rv32 path/to/program.hex
#
# Notes:
# - The simulator will auto-convert .elf to Intel HEX using riscv64-unknown-elf-objcopy
#   (or riscv32-unknown-elf-objcopy). Set RISCV_OBJCOPY to override if needed.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${ROOT_DIR}/build_result"
export WITH_RISCV_REF="${WITH_RISCV_REF:-no}"

command_exists() { command -v "$1" >/dev/null 2>&1; }

echo "[1/4] Checking prerequisites..."
if ! command_exists verilator; then
  echo "Error: verilator not found in PATH."
  exit 1
fi
if ! command_exists java; then
  echo "Error: java (JDK) not found in PATH."
  exit 1
fi

# Acquire sbt if missing (sbt-extras lightweight wrapper).
SBT_CMD="sbt"
if ! command_exists sbt; then
  SBT_CMD="${ROOT_DIR}/.sbtw"
  if [[ ! -x "${SBT_CMD}" ]]; then
    echo "[info] sbt not found; downloading sbt-extras wrapper..."
    curl -fsSL https://raw.githubusercontent.com/paulp/sbt-extras/master/sbt > "${SBT_CMD}"
    chmod +x "${SBT_CMD}"
  fi
fi

echo "[2/4] Generating RTL (VexRiscv.v) with Scala/SBT..."
if [[ ! -f "${ROOT_DIR}/VexRiscv.v" ]] || [[ "${FORCE_REGEN:-}" == "1" ]]; then
  pushd "${ROOT_DIR}" >/dev/null
  # Generate a RV32 core with maximum extensions (compressed, LR/SC, AMO, FPU D, S-mode, MMU)
  "${SBT_CMD}" "runMain vexriscv.demo.GenMax"
  popd >/dev/null
else
  echo "[skip] VexRiscv.v already present."
fi

echo "[3/4] Building Verilator simulation (rv32, max extensions)..."
pushd "${ROOT_DIR}/src/test/cpp/regression" >/dev/null
WITH_RISCV_REF="${WITH_RISCV_REF}" make clean
# Define RUN_HEX to enable the 'run' code path; runtime arg will override the image.
# Enable simulation flags to match GenMax features.
WITH_RISCV_REF="${WITH_RISCV_REF}" make verilate RUN_HEX="" COMPRESSED=yes LRSC=yes AMO=yes RVF=yes RVD=yes SUPERVISOR=yes MMU=yes IBUS_DATA_WIDTH=64 DBUS_LOAD_DATA_WIDTH=64 DBUS_STORE_DATA_WIDTH=64 TRACE_ACCESS=yes TRACE_WITH_TIME=yes
WITH_RISCV_REF="${WITH_RISCV_REF}" make -j"$(nproc)" -C obj_dir -f VVexRiscv.mk VVexRiscv
popd >/dev/null

echo "[4/4] Packaging..."
mkdir -p "${OUT_DIR}"
# Clean previous outputs to keep only the max-extensions binary
find "${OUT_DIR}" -maxdepth 1 -type f -exec rm -f {} +
cp -f "${ROOT_DIR}/src/test/cpp/regression/obj_dir/VVexRiscv" "${OUT_DIR}/vex_rv32"
chmod +x "${OUT_DIR}/vex_rv32"
echo "Done: ${OUT_DIR}/vex_rv32"

# RV64 status
echo
echo "Note about RV64:"
echo "  This repository (VexRiscv) implements a 32-bit RISC-V core (RV32)."
echo "  Building an RV64 core is not supported here; skipping rv64 build."
echo
echo "Run example:"
echo "  ${OUT_DIR}/vex_rv32 path/to/program.elf"
echo "  ${OUT_DIR}/vex_rv32 path/to/program.hex"
