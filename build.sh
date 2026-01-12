#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./build.sh [--coverage|--coverage-light|--no-coverage] [--clean] [--smp|--no-smp] [--help] [-- extra_verilator_args...]

Build Verilator-based VexRiscv simulators that accept an ELF/HEX path.
- Default builds RV32FD (GenMax), RV32F (GenMaxRv32F), and SMP 2-core (VexRiscvSmp2Gen) binaries in build_result/.
- Pass --coverage to build full coverage-enabled binaries (suffix *_cov) with Verilator --coverage.
- Pass --coverage-light to build lightweight coverage binaries (suffix *_cov_light) with line/user-only coverage.
- Arguments after "--" are forwarded to Verilator (e.g. -- --compiler clang).
EOF
}

COVERAGE_MODE="${COVERAGE_MODE:-none}" # none|full|light
BUILD_SMP="${BUILD_SMP:-yes}"
CLEAN=0
EXTRA_VERILATOR_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --coverage|-c) COVERAGE_MODE="full" ;;
        --coverage-light) COVERAGE_MODE="light" ;;
        --no-coverage|-n) COVERAGE_MODE="none" ;;
        --clean) CLEAN=1 ;;
        --smp) BUILD_SMP="yes" ;;
        --no-smp) BUILD_SMP="no" ;;
        --help|-h) usage; exit 0 ;;
        --) shift; EXTRA_VERILATOR_ARGS+=("$@"); break ;;
        *) EXTRA_VERILATOR_ARGS+=("$1") ;;
    esac
    shift || true
done

# Build Verilator-based VexRiscv simulators that accept an ELF/HEX path.
# Output binaries:
#   - build_result/vex_rv32_fd[[_cov|_cov_light]] : RV32IMAFD + S-mode + MMU (GenMax)
#   - build_result/vex_rv32_f[[_cov|_cov_light]]  : RV32IMAF  + S-mode + MMU (GenMaxRv32F)
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
SBT_CACHE_DIR="${ROOT_DIR}/.sbt-cache"

BIN_SUFFIX=""
BUILD_KIND="standard"
case "$COVERAGE_MODE" in
    full)
        BIN_SUFFIX="_cov"
        BUILD_KIND="full coverage"
        ;;
    light)
        BIN_SUFFIX="_cov_light"
        BUILD_KIND="light coverage"
        ;;
    none)
        BIN_SUFFIX=""
        BUILD_KIND="standard"
        ;;
esac

VERILATOR_ARGS_STR="${EXTRA_VERILATOR_ARGS[*]-}"
case "$COVERAGE_MODE" in
    full)
        if [[ -n "$VERILATOR_ARGS_STR" ]]; then
            VERILATOR_ARGS_STR="--coverage ${VERILATOR_ARGS_STR}"
        else
            VERILATOR_ARGS_STR="--coverage"
        fi
        ;;
    light)
        if [[ -n "$VERILATOR_ARGS_STR" ]]; then
            VERILATOR_ARGS_STR="--coverage-line --coverage-user --coverage-max-width 0 ${VERILATOR_ARGS_STR}"
        else
            VERILATOR_ARGS_STR="--coverage-line --coverage-user --coverage-max-width 0"
        fi
        ;;
    none)
        # No additional coverage flags
        ;;
esac

if [[ -n "$VERILATOR_ARGS_STR" ]]; then
    VERILATOR_ARGS_STR="${VERILATOR_ARGS_STR} -I${ROOT_DIR}/src/test/cpp/regression"
else
    VERILATOR_ARGS_STR="-I${ROOT_DIR}/src/test/cpp/regression"
fi

OUT_BIN_FD="${OUT_DIR}/vex_rv32_fd${BIN_SUFFIX}"
OUT_BIN_F="${OUT_DIR}/vex_rv32_f${BIN_SUFFIX}"
OUT_BIN_SMP="${OUT_DIR}/vex_rv32_smp_2c${BIN_SUFFIX}"

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

# Prefer the local sbt-extras wrapper so we can pin caches in-repo.
SBT_CMD="${SBT_CMD:-${ROOT_DIR}/.sbtw}"
if [[ "${SBT_CMD}" == "${ROOT_DIR}/.sbtw" ]]; then
  if [[ ! -x "${SBT_CMD}" ]]; then
    echo "[info] downloading sbt-extras wrapper..."
    curl -fsSL https://raw.githubusercontent.com/paulp/sbt-extras/master/sbt > "${SBT_CMD}"
    chmod +x "${SBT_CMD}"
  fi
else
  if ! command_exists "${SBT_CMD}"; then
    echo "Error: sbt command not found: ${SBT_CMD}"
    exit 1
  fi
fi

# Keep sbt caches under the repo to avoid global lock permission issues.
mkdir -p "${SBT_CACHE_DIR}/boot" "${SBT_CACHE_DIR}/sbt" "${SBT_CACHE_DIR}/ivy2" "${SBT_CACHE_DIR}/staging"
export SBT_OPTS="${SBT_OPTS:-} -Dsbt.boot.directory=${SBT_CACHE_DIR}/boot -Dsbt.global.base=${SBT_CACHE_DIR}/sbt -Dsbt.ivy.home=${SBT_CACHE_DIR}/ivy2 -Dsbt.global.staging=${SBT_CACHE_DIR}/staging -Duser.home=${ROOT_DIR}"

mkdir -p "${OUT_DIR}"
if (( CLEAN )); then
  rm -rf "${ROOT_DIR}/src/test/cpp/regression/obj_dir"
  rm -f "${OUT_DIR}/vex_rv32_fd" "${OUT_DIR}/vex_rv32_f" \
        "${OUT_DIR}/vex_rv32_fd_cov" "${OUT_DIR}/vex_rv32_f_cov" \
        "${OUT_DIR}/vex_rv32_fd_cov_light" "${OUT_DIR}/vex_rv32_f_cov_light"
else
  rm -f "${OUT_BIN_FD}" "${OUT_BIN_F}"
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

echo "[2/4] Building RV32FD (GenMax, RVF+RVD)..."
build_variant "RV32FD" "vexriscv.demo.GenMax" yes yes "${OUT_BIN_FD}"

echo "[3/4] Building RV32F (GenMaxRv32F, RVF only)..."
build_variant "RV32F" "vexriscv.demo.GenMaxRv32F" yes no "${OUT_BIN_F}"

if [[ "$BUILD_SMP" == "yes" ]]; then
    echo "[4/4] Building SMP 2-core (VexRiscvSmp2Gen)..."
    pushd "${ROOT_DIR}" >/dev/null
    "${SBT_CMD}" "runMain vexriscv.demo.smp.VexRiscvSmp2Gen"
    popd >/dev/null

    pushd "${ROOT_DIR}/src/test/cpp/regression" >/dev/null
    WITH_RISCV_REF="${WITH_RISCV_REF}" make clean
    WITH_RISCV_REF="${WITH_RISCV_REF}" VERILATOR_ARGS="${VERILATOR_ARGS_STR}" \
        make verilate RUN_HEX="" COMPRESSED=yes LRSC=yes AMO=yes SUPERVISOR=yes MMU=yes \
        IBUS_DATA_WIDTH=64 DBUS_LOAD_DATA_WIDTH=64 DBUS_STORE_DATA_WIDTH=64 TRACE_ACCESS=yes \
        TRACE_WITH_TIME=yes LINUX_SOC_SMP=yes MAIN_CPP=main_smp.cpp
    WITH_RISCV_REF="${WITH_RISCV_REF}" make -j"$(nproc)" -C obj_dir -f VVexRiscv.mk VVexRiscv
    cp -f "obj_dir/VVexRiscv" "${OUT_BIN_SMP}"
    chmod +x "${OUT_BIN_SMP}"
    popd >/dev/null
fi

echo "[5/5] Packaging..."
echo "Done: ${OUT_BIN_FD}"
echo "Done: ${OUT_BIN_F}"
if [[ "$BUILD_SMP" == "yes" ]]; then
  echo "Done: ${OUT_BIN_SMP}"
fi
if [[ "$COVERAGE_MODE" == "full" ]]; then
  echo "Coverage enabled (Verilator --coverage). Use +covfile=<path> when running to override logs/coverage.dat."
elif [[ "$COVERAGE_MODE" == "light" ]]; then
  echo "Light coverage enabled (--coverage-line --coverage-user). Use +covfile=<path> when running to override logs/coverage.dat."
fi

# RV64 status
echo
echo "Note about RV64:"
echo "  This repository (VexRiscv) implements a 32-bit RISC-V core (RV32)."
echo "  Building an RV64 core is not supported here; skipping rv64 build."
echo
echo "Run example:"
echo "  ${OUT_BIN_FD} path/to/program.elf   # RV32IMAFD"
echo "  ${OUT_BIN_F} path/to/program.elf    # RV32IMAF"
if [[ "$BUILD_SMP" == "yes" ]]; then
  echo "  ${OUT_BIN_SMP} path/to/program.elf  # SMP 2-core"
fi
