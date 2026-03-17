#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./build.sh [--isa ISA] [--cores N] [--coverage|--coverage-light|--no-coverage] [--clean] [--help] [-- extra_verilator_args...]

Build a Verilator-based VexRiscv simulator that accepts an ELF/HEX path.

Options:
  --isa ISA                  ISA tag used for output naming (default: rv32). VexRiscv is RV32-only.
  --cores N                  Core count tag used for output naming (default: 1). This branch supports N=1 only.
  --coverage                 Enable Verilator full coverage (suffix _cov)
  --coverage-light           Enable lightweight coverage (suffix _cov_light)
  --no-coverage              Disable coverage (default)
  --clean                    Remove regression obj_dir and output binary
  --help                     Show this help
  --                         Forward remaining args to Verilator

Output artifact:
  build_result/vexriscv_<isa>_<N>c[_cov|_cov_light]

Examples:
  ./build.sh --isa rv32 --cores 1 -- --compiler clang
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

ISA="rv32"
CORES=1
COVERAGE_MODE="none" # none|full|light
CLEAN=0
EXTRA_VERILATOR_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --isa)
      [[ $# -ge 2 ]] || die "--isa requires a value"
      ISA="$2"; shift
      ;;
    --isa=*)
      ISA="${1#*=}"
      ;;
    --cores)
      [[ $# -ge 2 ]] || die "--cores requires a value"
      CORES="$2"; shift
      ;;
    --cores=*)
      CORES="${1#*=}"
      ;;
    --coverage) COVERAGE_MODE="full" ;;
    --coverage-light) COVERAGE_MODE="light" ;;
    --no-coverage) COVERAGE_MODE="none" ;;
    --clean) CLEAN=1 ;;
    --help|-h) usage; exit 0 ;;
    --) shift; EXTRA_VERILATOR_ARGS+=("$@"); break ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

if ! [[ "$CORES" =~ ^[0-9]+$ ]]; then
  die "--cores must be a positive integer"
fi
if (( CORES < 1 )); then
  die "--cores must be >= 1"
fi

if [[ "${ISA,,}" != rv32 ]]; then
  die "This branch supports --isa rv32 only (requested: ${ISA})"
fi

if (( CORES != 1 )); then
  die "--cores ${CORES} requires SMP support (use the 2hart worktree)"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${ROOT_DIR}/build_result"
OUT_SUFFIX=""
case "$COVERAGE_MODE" in
  full) OUT_SUFFIX="_cov" ;;
  light) OUT_SUFFIX="_cov_light" ;;
  none) OUT_SUFFIX="" ;;
  *) die "internal: bad COVERAGE_MODE '$COVERAGE_MODE'" ;;
esac

OUT_BIN="${OUT_DIR}/vexriscv_${ISA,,}_${CORES}c${OUT_SUFFIX}"

command_exists() { command -v "$1" >/dev/null 2>&1; }

command_exists verilator || die "verilator not found in PATH"
command_exists java || die "java (JDK) not found in PATH"

SBT_CACHE_DIR="${ROOT_DIR}/.sbt-cache"
SBT_CMD="${SBT_CMD:-${ROOT_DIR}/.sbtw}"
if [[ "${SBT_CMD}" == "${ROOT_DIR}/.sbtw" ]]; then
  if [[ ! -x "${SBT_CMD}" ]]; then
    command_exists curl || die "curl not found (needed to download sbt-extras to .sbtw)"
    curl -fsSL https://raw.githubusercontent.com/paulp/sbt-extras/master/sbt > "${SBT_CMD}"
    chmod +x "${SBT_CMD}"
  fi
else
  command_exists "${SBT_CMD}" || die "sbt command not found: ${SBT_CMD}"
fi

mkdir -p "${SBT_CACHE_DIR}/boot" "${SBT_CACHE_DIR}/sbt" "${SBT_CACHE_DIR}/ivy2" "${SBT_CACHE_DIR}/staging"
export SBT_OPTS="${SBT_OPTS:-} -Dsbt.boot.directory=${SBT_CACHE_DIR}/boot -Dsbt.global.base=${SBT_CACHE_DIR}/sbt -Dsbt.ivy.home=${SBT_CACHE_DIR}/ivy2 -Dsbt.global.staging=${SBT_CACHE_DIR}/staging -Duser.home=${ROOT_DIR}"

mkdir -p "${OUT_DIR}"
if (( CLEAN )); then
  rm -rf "${ROOT_DIR}/src/test/cpp/regression/obj_dir"
  rm -f "${OUT_BIN}"
fi
rm -f "${OUT_BIN}"

SCALA_MAIN="vexriscv.demo.GenFull"

verilator_args=("-I${ROOT_DIR}/src/test/cpp/regression")
case "$COVERAGE_MODE" in
  full) verilator_args+=("--coverage") ;;
  light) verilator_args+=("--coverage-line" "--coverage-user" "--coverage-max-width" "0") ;;
esac
if ((${#EXTRA_VERILATOR_ARGS[@]})); then
  verilator_args+=("${EXTRA_VERILATOR_ARGS[@]}")
fi
VERILATOR_ARGS_STR="$(printf '%q ' "${verilator_args[@]}")"

echo "[1/3] Scala netlist generation: ${SCALA_MAIN}"
"${SBT_CMD}" "runMain ${SCALA_MAIN}"

echo "[2/3] Verilator build: ${OUT_BIN}"
pushd "${ROOT_DIR}/src/test/cpp/regression" >/dev/null
WITH_RISCV_REF="${WITH_RISCV_REF:-no}" make clean
WITH_RISCV_REF="${WITH_RISCV_REF:-no}" VERILATOR_ARGS="${VERILATOR_ARGS_STR}" \
  make verilate RUN_HEX="" MAIN_CPP=main.cpp TRACE_ACCESS=yes TRACE_WITH_TIME=yes
make -j"$(nproc)" -C obj_dir -f VVexRiscv.mk VVexRiscv
cp -f "obj_dir/VVexRiscv" "${OUT_BIN}"
chmod +x "${OUT_BIN}"
popd >/dev/null

echo "[3/3] Done: ${OUT_BIN}"
