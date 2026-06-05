#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./build.sh --isa <rv32f|rv32fd> --cores N [--out-dir DIR] [--coverage|--coverage-light|--no-coverage] [--clean] [--help] [-- extra_verilator_args...]

Build a Verilator-based VexRiscv simulator that accepts an ELF/HEX path.

Options:
  --isa <rv32f|rv32fd>        ISA selection (RV64 is unsupported; will error)
  --cores N                  Number of cores (supported: 1 or 2)
                             Note: SMP 2-core supports rv32fd only.
  --out-dir DIR              Output directory for the final binary (default: ./build_result)
                             You can also set CX_OUT_DIR (shared across repos) or OUT_DIR.
  --coverage                 Enable Verilator full coverage (suffix _cov)
  --coverage-light           Enable lightweight coverage (suffix _cov_light)
  --no-coverage              Disable coverage (default)
  --clean                    Remove regression obj_dir and output binary
  --help                     Show this help
  --                         Forward remaining args to Verilator

Output artifact:
  <out-dir>/vexriscv_<isa>_<N>c[_cov|_cov_light]

Examples:
  ./build.sh --isa rv32fd --cores 1
  ./build.sh --isa rv32f --cores 1 --coverage-light
  ./build.sh --isa rv32fd --cores 1 -- --compiler clang
  ./build.sh --isa rv32fd --cores 2
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

ISA="rv32fd"
CORES=1
COVERAGE_MODE="none" # none|full|light
CLEAN=0
OUT_DIR_OPT=""
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
    --out-dir)
      [[ $# -ge 2 ]] || die "--out-dir requires a value"
      OUT_DIR_OPT="$2"; shift
      ;;
    --out-dir=*)
      OUT_DIR_OPT="${1#*=}"
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
if (( CORES > 2 )); then
  die "--cores ${CORES} is unsupported (supported: 1 or 2)"
fi

case "${ISA,,}" in
  rv32f|rv32fd) ;;
  rv64|rv64*|riscv64|riscv64*) die "RV64 is unsupported in this repo" ;;
  *) die "unsupported --isa '${ISA}' (supported: rv32f rv32fd)" ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR_DEFAULT="${ROOT_DIR}/build_result"
OUT_DIR="${OUT_DIR_OPT:-${CX_OUT_DIR:-${OUT_DIR:-${OUT_DIR_DEFAULT}}}}"
OUT_SUFFIX=""
case "$COVERAGE_MODE" in
  full) OUT_SUFFIX="_cov" ;;
  light) OUT_SUFFIX="_cov_light" ;;
  none) OUT_SUFFIX="" ;;
  *) die "internal: bad COVERAGE_MODE '$COVERAGE_MODE'" ;;
esac

OUT_BIN="${OUT_DIR}/vexriscv_${ISA,,}_${CORES}c${OUT_SUFFIX}"

command_exists() { command -v "$1" >/dev/null 2>&1; }
java_major() {
  local java_bin="$1"
  local ver
  ver="$("${java_bin}" -version 2>&1 | awk -F '"' '/version/ {print $2; exit}')"
  [[ -n "${ver}" ]] || return 1
  if [[ "${ver}" == 1.* ]]; then
    printf '%s\n' "${ver#1.}" | cut -d. -f1
  else
    printf '%s\n' "${ver}" | cut -d. -f1
  fi
}

select_java_for_sbt() {
  local current_java=""
  if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
    current_java="${JAVA_HOME}/bin/java"
  else
    current_java="$(command -v java)"
  fi

  local current_major=""
  current_major="$(java_major "${current_java}" 2>/dev/null || true)"
  [[ -n "${current_major}" ]] || return 0

  # sbt 1.6.0 is unstable on some JDK 21 setups; prefer JDK 17 when available.
  if (( current_major >= 21 )); then
    local candidate=""
    local -a homes=()
    [[ -n "${JAVA_17_HOME:-}" ]] && homes+=("${JAVA_17_HOME}")
    [[ -d /usr/lib/jvm ]] && while IFS= read -r candidate; do
      homes+=("${candidate}")
    done < <(find /usr/lib/jvm -maxdepth 1 -type d \( -name 'java-17*' -o -name 'jdk-17*' \) | sort)

    for candidate in "${homes[@]}"; do
      if [[ -x "${candidate}/bin/java" ]]; then
        export JAVA_HOME="${candidate}"
        export PATH="${JAVA_HOME}/bin:${PATH}"
        echo "[info] Using Java $(java_major "${JAVA_HOME}/bin/java") from ${JAVA_HOME} for sbt compatibility"
        return 0
      fi
    done

    echo "[warn] Java ${current_major} detected, but no JDK 17 candidate was found; continuing with current java" >&2
  fi
}

command_exists verilator || die "verilator not found in PATH"
command_exists java || die "java (JDK) not found in PATH"
select_java_for_sbt

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

SCALA_MAIN=""
RVF="no"
RVD="no"
case "${ISA,,}" in
  rv32f)
    SCALA_MAIN="vexriscv.demo.GenMaxRv32F"
    RVF="yes"; RVD="no"
    ;;
  rv32fd)
    SCALA_MAIN="vexriscv.demo.GenMax"
    RVF="yes"; RVD="yes"
    ;;
esac

if (( CORES == 2 )); then
  if [[ "${ISA,,}" == "rv32f" ]]; then
    die "SMP 2-core build does not support --isa rv32f (use rv32fd)"
  fi
  SCALA_MAIN="vexriscv.demo.smp.VexRiscvLitexSmpClusterCmdGen"
fi

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
if (( CORES == 1 )); then
  "${SBT_CMD}" "runMain ${SCALA_MAIN}"
else
  smp_fpu="false"
  case "${ISA,,}" in
    rv32fd) smp_fpu="true" ;;
    *) die "internal: unexpected ISA for SMP build: ${ISA}" ;;
  esac
  "${SBT_CMD}" "runMain ${SCALA_MAIN} --cpu-count 2 --netlist-name VexRiscv --netlist-directory . --fpu ${smp_fpu} --rvc true"
fi

echo "[2/3] Verilator build: ${OUT_BIN}"
pushd "${ROOT_DIR}/src/test/cpp/regression" >/dev/null
WITH_RISCV_REF="${WITH_RISCV_REF:-no}" make clean
WITH_RISCV_REF="${WITH_RISCV_REF:-no}" VERILATOR_ARGS="${VERILATOR_ARGS_STR}" \
  make verilate RUN_HEX="" MAIN_CPP="$([[ ${CORES} -eq 2 ]] && echo main_smp.cpp || echo main.cpp)" \
  COMPRESSED=yes LRSC=yes AMO=yes \
  RVF="${RVF}" RVD="${RVD}" \
  SUPERVISOR=yes MMU=yes CSR=yes $([[ ${CORES} -eq 2 ]] && echo LINUX_SOC_SMP=yes || true) \
  IBUS_DATA_WIDTH=64 DBUS_LOAD_DATA_WIDTH=64 DBUS_STORE_DATA_WIDTH=64 \
  TRACE_ACCESS=yes TRACE_WITH_TIME=yes
make -j"$(nproc)" -C obj_dir -f VVexRiscv.mk VVexRiscv
cp -f "obj_dir/VVexRiscv" "${OUT_BIN}"
chmod +x "${OUT_BIN}"
popd >/dev/null

echo "[3/3] Done: ${OUT_BIN}"
