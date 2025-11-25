#!/usr/bin/env bash
set -euo pipefail

# Build Verilator-based VexRiscv simulators that accept an ELF/HEX path.
# Output binaries:
#   - build_result/vex_rv32d : RV32IMAFD + S-mode + MMU (GenMax)
#   - build_result/vex_rv32f : RV32IMAF  + S-mode + MMU (GenMaxRv32F)
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

mkdir -p "${OUT_DIR}"
rm -f "${OUT_DIR}/vex_rv32d" "${OUT_DIR}/vex_rv32f"

echo "[2/4] Building RV32D (GenMax, RVF+RVD)..."
pushd "${ROOT_DIR}" >/dev/null
"${SBT_CMD}" "runMain vexriscv.demo.GenMax"
popd >/dev/null

pushd "${ROOT_DIR}/src/test/cpp/regression" >/dev/null
WITH_RISCV_REF="${WITH_RISCV_REF}" make clean
WITH_RISCV_REF="${WITH_RISCV_REF}" make verilate RUN_HEX="" COMPRESSED=yes LRSC=yes AMO=yes RVF=yes RVD=yes SUPERVISOR=yes MMU=yes IBUS_DATA_WIDTH=64 DBUS_LOAD_DATA_WIDTH=64 DBUS_STORE_DATA_WIDTH=64 TRACE_ACCESS=yes TRACE_WITH_TIME=yes
WITH_RISCV_REF="${WITH_RISCV_REF}" make -j"$(nproc)" -C obj_dir -f VVexRiscv.mk VVexRiscv
cp -f "${ROOT_DIR}/src/test/cpp/regression/obj_dir/VVexRiscv" "${OUT_DIR}/vex_rv32d"
chmod +x "${OUT_DIR}/vex_rv32d"
popd >/dev/null

echo "[3/4] Building RV32F (GenMaxRv32F, RVF only)..."
pushd "${ROOT_DIR}" >/dev/null
"${SBT_CMD}" "runMain vexriscv.demo.GenMaxRv32F"
popd >/dev/null

pushd "${ROOT_DIR}/src/test/cpp/regression" >/dev/null
WITH_RISCV_REF="${WITH_RISCV_REF}" make clean
WITH_RISCV_REF="${WITH_RISCV_REF}" make verilate RUN_HEX="" COMPRESSED=yes LRSC=yes AMO=yes RVF=yes RVD=no SUPERVISOR=yes MMU=yes IBUS_DATA_WIDTH=64 DBUS_LOAD_DATA_WIDTH=64 DBUS_STORE_DATA_WIDTH=64 TRACE_ACCESS=yes TRACE_WITH_TIME=yes
WITH_RISCV_REF="${WITH_RISCV_REF}" make -j"$(nproc)" -C obj_dir -f VVexRiscv.mk VVexRiscv
cp -f "${ROOT_DIR}/src/test/cpp/regression/obj_dir/VVexRiscv" "${OUT_DIR}/vex_rv32f"
chmod +x "${OUT_DIR}/vex_rv32f"
popd >/dev/null

echo "[4/4] Packaging..."
echo "Done: ${OUT_DIR}/vex_rv32d"
echo "Done: ${OUT_DIR}/vex_rv32f"

# RV64 status
echo
echo "Note about RV64:"
echo "  This repository (VexRiscv) implements a 32-bit RISC-V core (RV32)."
echo "  Building an RV64 core is not supported here; skipping rv64 build."
echo
echo "Run example:"
echo "  ${OUT_DIR}/vex_rv32d path/to/program.elf   # RV32IMAFD"
echo "  ${OUT_DIR}/vex_rv32f path/to/program.elf   # RV32IMAF"
