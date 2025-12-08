#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./build.sh [--coverage] [--no-coverage] [--clean] [--help] [-- extra_verilator_args...]

Build Verilator-based VexRiscv simulators that accept an ELF/HEX path.
- Default builds RV32D (GenMax) and RV32F (GenMaxRv32F) binaries in build_result/.
- Pass --coverage to build coverage-enabled binaries (suffix *_cov) with Verilator --coverage.
- Arguments after "--" are forwarded to Verilator (e.g. -- --compiler clang).
EOF
}

COVERAGE=0
CLEAN=0
EXTRA_VERILATOR_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --coverage|-c) COVERAGE=1 ;;
        --no-coverage|-n) COVERAGE=0 ;;
        --clean) CLEAN=1 ;;
        --help|-h) usage; exit 0 ;;
        --) shift; EXTRA_VERILATOR_ARGS+=("$@"); break ;;
        *) EXTRA_VERILATOR_ARGS+=("$1") ;;
    esac
    shift || true
done

# Build Verilator-based VexRiscv simulators that accept an ELF/HEX path.
# Output binaries:
#   - build_result/vex_rv32d[[_cov]] : RV32IMAFD + S-mode + MMU (GenMax)
#   - build_result/vex_rv32f[[_cov]] : RV32IMAF  + S-mode + MMU (GenMaxRv32F)
#
# Requirements:
# - Java (for Scala codegen)
# - sbt (or network to fetch sbt-extras automatically)
# - Verilator (v4+ recommended, v5 tested)
# - A C++ toolchain (g++, make)
#
# Notes:
# - The simulator will auto-convert .elf to Intel HEX using riscv64-unknown-elf-objcopy
#   (or riscv32-unknown-elf-objcopy). Set RISCV_OBJCOPY to override if needed.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${ROOT_DIR}/build_result"
export WITH_RISCV_REF="${WITH_RISCV_REF:-no}"

BIN_SUFFIX=""
BUILD_KIND="standard"
if (( COVERAGE )); then
    BIN_SUFFIX="_cov"
    BUILD_KIND="coverage"
fi

VERILATOR_ARGS_STR="${EXTRA_VERILATOR_ARGS[*]-}"
if (( COVERAGE )); then
    if [[ -n "$VERILATOR_ARGS_STR" ]]; then
        VERILATOR_ARGS_STR="--coverage ${VERILATOR_ARGS_STR}"
    else
        VERILATOR_ARGS_STR="--coverage"
    fi
fi

OUT_BIN_D="${OUT_DIR}/vex_rv32d${BIN_SUFFIX}"
OUT_BIN_F="${OUT_DIR}/vex_rv32f${BIN_SUFFIX}"

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
if (( CLEAN )); then
  rm -rf "${ROOT_DIR}/src/test/cpp/regression/obj_dir"
  rm -f "${OUT_DIR}/vex_rv32d" "${OUT_DIR}/vex_rv32f" "${OUT_DIR}/vex_rv32d_cov" "${OUT_DIR}/vex_rv32f_cov"
else
  rm -f "${OUT_BIN_D}" "${OUT_BIN_F}"
fi

build_variant() {
    local name="$1"
    local scala_class="$2"
    local rvf="$3"
    local rvd="$4"
    local out_bin="$5"

    echo "[build] ${name} (${BUILD_KIND}) -> ${out_bin}"
    pushd "${ROOT_DIR}" >/dev/null
    "${SBT_CMD}" "runMain ${scala_class}"
    popd >/dev/null

    pushd "${ROOT_DIR}/src/test/cpp/regression" >/dev/null
    WITH_RISCV_REF="${WITH_RISCV_REF}" make clean
    WITH_RISCV_REF="${WITH_RISCV_REF}" VERILATOR_ARGS="${VERILATOR_ARGS_STR}" \
        make verilate RUN_HEX="" COMPRESSED=yes LRSC=yes AMO=yes RVF="${rvf}" RVD="${rvd}" SUPERVISOR=yes MMU=yes IBUS_DATA_WIDTH=64 DBUS_LOAD_DATA_WIDTH=64 DBUS_STORE_DATA_WIDTH=64 TRACE_ACCESS=yes TRACE_WITH_TIME=yes
    WITH_RISCV_REF="${WITH_RISCV_REF}" make -j"$(nproc)" -C obj_dir -f VVexRiscv.mk VVexRiscv
    cp -f "obj_dir/VVexRiscv" "${out_bin}"
    chmod +x "${out_bin}"
    popd >/dev/null
}

echo "[2/4] Building RV32D (GenMax, RVF+RVD)..."
build_variant "RV32D" "vexriscv.demo.GenMax" yes yes "${OUT_BIN_D}"

echo "[3/4] Building RV32F (GenMaxRv32F, RVF only)..."
build_variant "RV32F" "vexriscv.demo.GenMaxRv32F" yes no "${OUT_BIN_F}"

echo "[4/4] Packaging..."
echo "Done: ${OUT_BIN_D}"
echo "Done: ${OUT_BIN_F}"
if (( COVERAGE )); then
  echo "Coverage enabled (Verilator --coverage). Use +covfile=<path> when running to override logs/coverage.dat."
fi

# RV64 status
echo
echo "Note about RV64:"
echo "  This repository (VexRiscv) implements a 32-bit RISC-V core (RV32)."
echo "  Building an RV64 core is not supported here; skipping rv64 build."
echo
echo "Run example:"
echo "  ${OUT_BIN_D} path/to/program.elf   # RV32IMAFD"
echo "  ${OUT_BIN_F} path/to/program.elf   # RV32IMAF"
