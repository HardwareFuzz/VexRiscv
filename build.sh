#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./build.sh [--coverage|--coverage-light|--no-coverage] [--memorder <cache|store-buffer|fence|atomic>] [--memorder-smp <cache|store-buffer|fence|atomic>] [--clean] [--smp|--no-smp] [--help] [-- extra_verilator_args...]

Build Verilator-based VexRiscv simulators that accept an ELF/HEX path.
- Default builds RV32FD (GenMax), RV32F (GenMaxRv32F), and SMP 2-core (VexRiscvSmp2Gen) binaries in build_result/.
- Pass --memorder <name> to build a GenMemOrder variant (cache/store-buffer/fence/atomic) in build_result/.
- Pass --memorder-smp <name> to build an SMP 2-core MemOrder variant via VexRiscvSmp2Gen.
- Pass --coverage to build full coverage-enabled binaries (suffix *_cov) with Verilator --coverage.
- Pass --coverage-light to build lightweight coverage binaries (suffix *_cov_light) with line/user-only coverage.
- Arguments after "--" are forwarded to Verilator (e.g. -- --compiler clang).
EOF
}

COVERAGE_MODE="${COVERAGE_MODE:-none}" # none|full|light
BUILD_SMP="${BUILD_SMP:-yes}"
CLEAN=0
MEMORDER_VARIANT="${MEMORDER_VARIANT:-}"
MEMORDER_SMP_VARIANT="${MEMORDER_SMP_VARIANT:-}"
EXTRA_VERILATOR_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --coverage|-c) COVERAGE_MODE="full" ;;
        --coverage-light) COVERAGE_MODE="light" ;;
        --no-coverage|-n) COVERAGE_MODE="none" ;;
        --memorder)
            if [[ $# -lt 2 ]]; then
                echo "Error: --memorder requires a variant name."
                exit 1
            fi
            MEMORDER_VARIANT="$2"
            shift
            ;;
        --memorder=*) MEMORDER_VARIANT="${1#*=}" ;;
        --memorder-smp)
            if [[ $# -lt 2 ]]; then
                echo "Error: --memorder-smp requires a variant name."
                exit 1
            fi
            MEMORDER_SMP_VARIANT="$2"
            shift
            ;;
        --memorder-smp=*) MEMORDER_SMP_VARIANT="${1#*=}" ;;
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
#   - build_result/vex_rv32_memorder_<name>[[_cov|_cov_light]] : MemOrder variant (GenMemOrder, optional)
#   - build_result/vex_rv32_smp_2c_memorder_<name>[[_cov|_cov_light]] : SMP 2-core MemOrder variant (VexRiscvSmp2Gen, optional)
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
OUT_BIN_MEMORDER=""
OUT_BIN_SMP_MEMORDER=""

normalize_memorder_variant() {
  local value="${1,,}"
  case "${value}" in
    cache) echo "cache" ;;
    store-buffer|store_buffer|storebuffer) echo "store-buffer" ;;
    fence) echo "fence" ;;
    atomic) echo "atomic" ;;
    *) return 1 ;;
  esac
}

if [[ -n "$MEMORDER_VARIANT" ]]; then
  raw_memorder_variant="$MEMORDER_VARIANT"
  if ! MEMORDER_VARIANT="$(normalize_memorder_variant "$MEMORDER_VARIANT")"; then
    echo "Error: unknown memorder variant: ${raw_memorder_variant}"
    exit 1
  fi
  OUT_BIN_MEMORDER="${OUT_DIR}/vex_rv32_memorder_${MEMORDER_VARIANT}${BIN_SUFFIX}"
fi

if [[ -n "$MEMORDER_SMP_VARIANT" ]]; then
  raw_memorder_smp_variant="$MEMORDER_SMP_VARIANT"
  if ! MEMORDER_SMP_VARIANT="$(normalize_memorder_variant "$MEMORDER_SMP_VARIANT")"; then
    echo "Error: unknown memorder SMP variant: ${raw_memorder_smp_variant}"
    exit 1
  fi
  OUT_BIN_SMP_MEMORDER="${OUT_DIR}/vex_rv32_smp_2c_memorder_${MEMORDER_SMP_VARIANT}${BIN_SUFFIX}"
fi

command_exists() { command -v "$1" >/dev/null 2>&1; }

TOTAL_STEPS=4
if [[ "$BUILD_SMP" == "yes" ]]; then
  TOTAL_STEPS=$((TOTAL_STEPS + 1))
fi
if [[ -n "$MEMORDER_VARIANT" ]]; then
  TOTAL_STEPS=$((TOTAL_STEPS + 1))
fi
if [[ -n "$MEMORDER_SMP_VARIANT" ]]; then
  TOTAL_STEPS=$((TOTAL_STEPS + 1))
fi
STEP=1

echo "[${STEP}/${TOTAL_STEPS}] Checking prerequisites..."
STEP=$((STEP + 1))
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
  rm -f "${OUT_DIR}/vex_rv32_smp_2c" \
        "${OUT_DIR}/vex_rv32_smp_2c_cov" \
        "${OUT_DIR}/vex_rv32_smp_2c_cov_light"
  if [[ -n "$MEMORDER_VARIANT" ]]; then
    rm -f "${OUT_DIR}/vex_rv32_memorder_${MEMORDER_VARIANT}" \
          "${OUT_DIR}/vex_rv32_memorder_${MEMORDER_VARIANT}_cov" \
          "${OUT_DIR}/vex_rv32_memorder_${MEMORDER_VARIANT}_cov_light"
  fi
  if [[ -n "$MEMORDER_SMP_VARIANT" ]]; then
    rm -f "${OUT_DIR}/vex_rv32_smp_2c_memorder_${MEMORDER_SMP_VARIANT}" \
          "${OUT_DIR}/vex_rv32_smp_2c_memorder_${MEMORDER_SMP_VARIANT}_cov" \
          "${OUT_DIR}/vex_rv32_smp_2c_memorder_${MEMORDER_SMP_VARIANT}_cov_light"
  fi
else
  rm -f "${OUT_BIN_FD}" "${OUT_BIN_F}"
  if [[ -n "$OUT_BIN_MEMORDER" ]]; then
    rm -f "${OUT_BIN_MEMORDER}"
  fi
  if [[ "$BUILD_SMP" == "yes" ]]; then
    rm -f "${OUT_BIN_SMP}"
  fi
  if [[ -n "$OUT_BIN_SMP_MEMORDER" ]]; then
    rm -f "${OUT_BIN_SMP_MEMORDER}"
  fi
fi

build_variant() {
    local name="$1"
    local scala_class="$2"
    local rvf="$3"
    local rvd="$4"
    local out_bin="$5"
    local extra_make_args=("${@:6}")

    echo "[build] ${name} (${BUILD_KIND}) -> ${out_bin}"
    pushd "${ROOT_DIR}" >/dev/null
    "${SBT_CMD}" "runMain ${scala_class}"
    popd >/dev/null

    pushd "${ROOT_DIR}/src/test/cpp/regression" >/dev/null
    WITH_RISCV_REF="${WITH_RISCV_REF}" make clean
    WITH_RISCV_REF="${WITH_RISCV_REF}" VERILATOR_ARGS="${VERILATOR_ARGS_STR}" \
        make verilate RUN_HEX="" COMPRESSED=yes LRSC=yes AMO=yes RVF="${rvf}" RVD="${rvd}" SUPERVISOR=yes MMU=yes CSR=yes IBUS_DATA_WIDTH=64 DBUS_LOAD_DATA_WIDTH=64 DBUS_STORE_DATA_WIDTH=64 TRACE_ACCESS=yes TRACE_WITH_TIME=yes "${extra_make_args[@]}"
    WITH_RISCV_REF="${WITH_RISCV_REF}" make -j"$(nproc)" -C obj_dir -f VVexRiscv.mk VVexRiscv
    cp -f "obj_dir/VVexRiscv" "${out_bin}"
    chmod +x "${out_bin}"
    popd >/dev/null
}

build_memorder_variant() {
    local variant="$1"
    local out_bin="$2"
    local lrsc="no"
    local amo="no"
    local dbus_exclusive="no"
    local dbus_invalidate="no"

    case "$variant" in
      cache) ;;
      store-buffer) ;;
      fence)
        dbus_invalidate="yes"
        ;;
      atomic)
        dbus_exclusive="yes"
        dbus_invalidate="yes"
        lrsc="yes"
        amo="yes"
        ;;
    esac

    local make_args=(
      "COMPRESSED=no"
      "LRSC=${lrsc}"
      "AMO=${amo}"
      "MMU=no"
      "SUPERVISOR=no"
      "IBUS_DATA_WIDTH=32"
      "DBUS_LOAD_DATA_WIDTH=32"
      "DBUS_STORE_DATA_WIDTH=32"
    )
    if [[ "$dbus_exclusive" == "yes" ]]; then
      make_args+=("DBUS_EXCLUSIVE=yes")
    fi
    if [[ "$dbus_invalidate" == "yes" ]]; then
      make_args+=("DBUS_INVALIDATE=yes")
    fi

    build_variant "MemOrder (${variant})" "vexriscv.demo.GenMemOrder ${variant}" no no "${out_bin}" "${make_args[@]}"
}

build_smp_memorder_variant() {
    local variant="$1"
    local out_bin="$2"
    local lrsc="no"
    local amo="no"
    local dbus_exclusive="no"
    local dbus_invalidate="no"

    case "$variant" in
      cache) ;;
      store-buffer) ;;
      fence)
        dbus_invalidate="yes"
        ;;
      atomic)
        dbus_exclusive="yes"
        dbus_invalidate="yes"
        lrsc="yes"
        amo="yes"
        ;;
    esac

    local make_args=(
      "COMPRESSED=yes"
      "LRSC=${lrsc}"
      "AMO=${amo}"
      "SUPERVISOR=yes"
      "MMU=yes"
      "IBUS_DATA_WIDTH=64"
      "DBUS_LOAD_DATA_WIDTH=64"
      "DBUS_STORE_DATA_WIDTH=64"
      "TRACE_ACCESS=yes"
      "TRACE_WITH_TIME=yes"
      "LINUX_SOC_SMP=yes"
      "CSR=yes"
      "MAIN_CPP=main_smp.cpp"
    )
    if [[ "$dbus_exclusive" == "yes" ]]; then
      make_args+=("DBUS_EXCLUSIVE=yes")
    fi
    if [[ "$dbus_invalidate" == "yes" ]]; then
      make_args+=("DBUS_INVALIDATE=yes")
    fi

    pushd "${ROOT_DIR}" >/dev/null
    "${SBT_CMD}" "runMain vexriscv.demo.smp.VexRiscvSmp2Gen --memorder ${variant} --ibus-width 32 --dbus-width 32 --csr-full"
    popd >/dev/null

    pushd "${ROOT_DIR}/src/test/cpp/regression" >/dev/null
    WITH_RISCV_REF="${WITH_RISCV_REF}" make clean
    WITH_RISCV_REF="${WITH_RISCV_REF}" VERILATOR_ARGS="${VERILATOR_ARGS_STR}" \
        make verilate RUN_HEX="" CSR=yes "${make_args[@]}"
    WITH_RISCV_REF="${WITH_RISCV_REF}" make -j"$(nproc)" -C obj_dir -f VVexRiscv.mk VVexRiscv
    cp -f "obj_dir/VVexRiscv" "${out_bin}"
    chmod +x "${out_bin}"
    popd >/dev/null
}

echo "[${STEP}/${TOTAL_STEPS}] Building RV32FD (GenMax, RVF+RVD)..."
STEP=$((STEP + 1))
build_variant "RV32FD" "vexriscv.demo.GenMax" yes yes "${OUT_BIN_FD}"

echo "[${STEP}/${TOTAL_STEPS}] Building RV32F (GenMaxRv32F, RVF only)..."
STEP=$((STEP + 1))
build_variant "RV32F" "vexriscv.demo.GenMaxRv32F" yes no "${OUT_BIN_F}"

if [[ -n "$MEMORDER_VARIANT" ]]; then
    echo "[${STEP}/${TOTAL_STEPS}] Building memorder (${MEMORDER_VARIANT})..."
    STEP=$((STEP + 1))
    build_memorder_variant "${MEMORDER_VARIANT}" "${OUT_BIN_MEMORDER}"
fi

if [[ "$BUILD_SMP" == "yes" ]]; then
    echo "[${STEP}/${TOTAL_STEPS}] Building SMP 2-core (VexRiscvSmp2Gen)..."
    STEP=$((STEP + 1))
    pushd "${ROOT_DIR}" >/dev/null
    "${SBT_CMD}" "runMain vexriscv.demo.smp.VexRiscvSmp2Gen --csr-full"
    popd >/dev/null

    pushd "${ROOT_DIR}/src/test/cpp/regression" >/dev/null
    WITH_RISCV_REF="${WITH_RISCV_REF}" make clean
    WITH_RISCV_REF="${WITH_RISCV_REF}" VERILATOR_ARGS="${VERILATOR_ARGS_STR}" \
        make verilate RUN_HEX="" COMPRESSED=yes LRSC=yes AMO=yes SUPERVISOR=yes MMU=yes CSR=yes \
        IBUS_DATA_WIDTH=64 DBUS_LOAD_DATA_WIDTH=64 DBUS_STORE_DATA_WIDTH=64 TRACE_ACCESS=yes \
        TRACE_WITH_TIME=yes LINUX_SOC_SMP=yes MAIN_CPP=main_smp.cpp
    WITH_RISCV_REF="${WITH_RISCV_REF}" make -j"$(nproc)" -C obj_dir -f VVexRiscv.mk VVexRiscv
    cp -f "obj_dir/VVexRiscv" "${OUT_BIN_SMP}"
    chmod +x "${OUT_BIN_SMP}"
    popd >/dev/null
fi

if [[ -n "$MEMORDER_SMP_VARIANT" ]]; then
    echo "[${STEP}/${TOTAL_STEPS}] Building SMP memorder (${MEMORDER_SMP_VARIANT})..."
    STEP=$((STEP + 1))
    build_smp_memorder_variant "${MEMORDER_SMP_VARIANT}" "${OUT_BIN_SMP_MEMORDER}"
fi

echo "[${STEP}/${TOTAL_STEPS}] Packaging..."
echo "Done: ${OUT_BIN_FD}"
echo "Done: ${OUT_BIN_F}"
if [[ -n "$OUT_BIN_MEMORDER" ]]; then
  echo "Done: ${OUT_BIN_MEMORDER}"
fi
if [[ "$BUILD_SMP" == "yes" ]]; then
  echo "Done: ${OUT_BIN_SMP}"
fi
if [[ -n "$OUT_BIN_SMP_MEMORDER" ]]; then
  echo "Done: ${OUT_BIN_SMP_MEMORDER}"
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
if [[ -n "$OUT_BIN_SMP_MEMORDER" ]]; then
  echo "  ${OUT_BIN_SMP_MEMORDER} path/to/program.elf  # SMP 2-core memorder"
fi
