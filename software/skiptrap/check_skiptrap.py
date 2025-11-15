#!/usr/bin/env python3
import re
import subprocess
import sys
from pathlib import Path

FREGTRACE = re.compile(r"^(?:\s*\d+\s+)?PC\s+([0-9a-fA-F]{8})\s+:\s+f\[\s*(\d+)\s*\]\s*=\s*0x([0-9a-fA-F]+)\s*$")
MEMTRACE = re.compile(r"^(?:\s*\d+\s+)?PC\s+([0-9a-fA-F]{8})\s+:\s+MEM\[(0x[0-9a-fA-F]+)\]\s+<=\s+(\d+)\s+bytes\s+:\s+0x([0-9a-fA-F]+)")
ASM_LINE = re.compile(r"^\s*([0-9a-fA-F]{8}):\s+(.*)$")
EXC_LINE = re.compile(r"^EXC\s+pc=0x([0-9a-fA-F]{8})\s+cause=(\d+)\s*$")

ASM_FPCS = {
    "flw_ft0"         : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+flw\s+ft0,0\(t2\)"),
    "fadd_s_ft1"      : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fadd\.s\s+ft1,ft0,ft0"),
    "fsub_s_ft2"      : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fsub\.s\s+ft2,ft1,ft0"),
    "fmul_s_ft3"      : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fmul\.s\s+ft3,ft0,ft0"),
    "fdiv_s_ft4"      : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fdiv\.s\s+ft4,ft1,ft0"),
    "fcvt_s_w_ft5"    : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fcvt\.s\.w\s+ft5,t5"),
    "fmv_s_ft6"       : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fmv\.s\s+ft6,ft0"),
    "fneg_s_ft7"      : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fneg\.s\s+ft7,ft0"),
    "fabs_s_fs0"      : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fabs\.s\s+fs0,ft0"),
    "fmin_s_fs1"      : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fmin\.s\s+fs1,ft0,ft1"),
    "fmax_s_fa0"      : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fmax\.s\s+fa0,ft0,ft1"),
    "fmadd_s_fa2"     : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fmadd\.s\s+fa2,ft0,ft0,ft0"),
    "fnmsub_s_fa3"    : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fnmsub\.s\s+fa3,ft0,ft0,ft0"),
    "fmadd_s_fa4"     : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fmadd\.s\s+fa4,ft1,ft0,ft0"),
    "fmsub_s_fa5"     : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fmsub\.s\s+fa5,ft1,ft0,ft0"),
    "fcvt_s_wu_fa6"   : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fcvt\.s\.wu\s+fa6,t6"),
    "fnmadd_s_fs6"    : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fnmadd\.s\s+fs6,fs2,fs4,fs7"),
    "fld_ft2"         : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fld\s+ft2,0\(t2\)"),
    "fadd_d_ft3"      : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fadd\.d\s+ft3,ft2,ft2"),
    "fcvt_d_w_ft4"    : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fcvt\.d\.w\s+ft4,t3"),
    "fmv_w_x_fa1"     : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fmv\.w\.x\s+fa1,t1"),
    "fmul_d_fs2"      : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fmul\.d\s+fs2,ft2,ft2"),
    "fmadd_d_fs3"     : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fmadd\.d\s+fs3,ft2,ft2,ft2"),
    "fmsub_d_fs4"     : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fmsub\.d\s+fs4,ft3,ft2,ft2"),
    "fsub_d_fs5"      : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fsub\.d\s+fs5,ft3,ft2"),
    "fmax_d_fs3"      : re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+fmax\.d\s+fs3,fs2,fs4"),
}

def parse_fregtrace(path):
    entries = []
    if not path.exists():
        return entries
    with path.open('r', errors='ignore') as f:
        for line in f:
            match = FREGTRACE.match(line)
            if not match:
                continue
            pc = int(match.group(1), 16)
            rd = int(match.group(2))
            hexs = match.group(3).lower()
            entries.append({"pc": pc, "rd": rd, "val": int(hexs, 16), "hexlen": len(hexs)})
    return entries

def parse_memtrace(path):
    entries = []
    if not path.exists():
        return entries
    with path.open('r', errors='ignore') as f:
        for line in f:
            match = MEMTRACE.match(line)
            if not match:
                continue
            entries.append({
                "pc": int(match.group(1), 16),
                "addr": int(match.group(2), 16),
                "size": int(match.group(3)),
                "value": int(match.group(4), 16),
            })
    return entries

def parse_asm_pcs(path):
    pcs = {}
    with path.open('r', errors='ignore') as f:
        for line in f:
            for key, regex in ASM_FPCS.items():
                if key in pcs:
                    continue
                match = regex.search(line)
                if match:
                    pcs[key] = int(match.group(1), 16)
    return pcs

def asm_map_by_pc(path):
    mapping = {}
    with path.open('r', errors='ignore') as f:
        for line in f:
            match = ASM_LINE.match(line)
            if match:
                mapping[int(match.group(1), 16)] = match.group(2).strip()
    return mapping


def parse_exc_log(path):
    entries = []
    if not path.exists():
        return entries
    with path.open('r', errors='ignore') as f:
        for line in f:
            m = EXC_LINE.match(line.strip())
            if not m:
                continue
            entries.append({
                "pc": int(m.group(1), 16),
                "cause": int(m.group(2)),
            })
    return entries

def find_fwrite(entries, rd, val, bits=None, pc=None):
    for entry in entries:
        if entry["rd"] != rd:
            continue
        if bits == 32 and entry["hexlen"] > 8:
            continue
        if bits == 64 and entry["hexlen"] < 16:
            continue
        if entry["val"] == val and (pc is None or entry["pc"] == pc):
            return entry
    return None

def matching_entries(entries, rd, bits=None):
    out = []
    for entry in entries:
        if entry["rd"] != rd:
            continue
        if bits == 32 and entry["hexlen"] > 8:
            continue
        if bits == 64 and entry["hexlen"] < 16:
            continue
        out.append(entry)
    return out

def load_symbol_map(elf_path):
    try:
        result = subprocess.run(
            ["riscv64-unknown-elf-nm", str(elf_path)],
            text=True,
            capture_output=True,
            check=True,
        )
    except FileNotFoundError:
        return {}, "[mem] riscv64-unknown-elf-nm not found"
    except subprocess.CalledProcessError as exc:
        msg = exc.stderr.strip() or exc.stdout.strip() or str(exc)
        return {}, f"[mem] nm failed: {msg}"

    symbols = {}
    for line in result.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) != 3:
            continue
        try:
            symbols[parts[2]] = int(parts[0], 16)
        except ValueError:
            continue
    return symbols, None

def expected_mem_sequence():
    return [
        {"label": "buf",                 "size": 4, "value": 0x12345678,             "asm": r"sw\s+s0,0\(t2\)"},
        {"label": "buf_byte",            "size": 1, "value": 0x78,                   "asm": r"sb\s+s0,0\(t2\)"},
        {"label": "buf_half",            "size": 2, "value": 0x5678,                 "asm": r"sh\s+s0,0\(t2\)"},
        {"label": "buf2",                "size": 4, "value": 0x13579BDF,             "asm": r"sw\s+s4,0\(t2\)"},
        {"label": "amo1",                "size": 4, "value": 0x11223344,             "asm": r"amoswap\.w"},
        {"label": "amo2",                "size": 4, "value": 0x00000015,             "asm": r"amoadd\.w"},
        {"label": "amo3",                "size": 4, "value": 0x00F0F0F0,             "asm": r"amoor\.w"},
        {"label": "amo4",                "size": 4, "value": 0x00FF00FF,             "asm": r"amoand\.w"},
        {"label": "amo5",                "size": 4, "value": 0xFFFFFFFE,             "asm": r"amomin\.w"},
        {"label": "amo6",                "size": 4, "value": 0x00000005,             "asm": r"amomax\.w"},
        {"label": "f32_out",             "size": 4, "value": 0x40400000,             "asm": r"fsw\s+ft1"},
        {"label": "f32_sub_out",         "size": 4, "value": 0x3FC00000,             "asm": r"fsw\s+ft2"},
        {"label": "f32_mul_out",         "size": 4, "value": 0x40100000,             "asm": r"fsw\s+ft3"},
        {"label": "f32_div_out",         "size": 4, "value": 0x40000000,             "asm": r"fsw\s+ft4"},
        {"label": "f32_i_out",           "size": 4, "value": 0x00000003,             "asm": r"sw\s+t5"},
        {"label": "f32_cvt_back_out",    "size": 4, "value": 0x40400000,             "asm": r"fsw\s+ft5"},
        {"label": "f32_sgnj_out",        "size": 4, "value": 0x3FC00000,             "asm": r"fsw\s+ft6"},
        {"label": "f32_sgnjn_out",       "size": 4, "value": 0xBFC00000,             "asm": r"fsw\s+ft7"},
        {"label": "f32_sgnjx_out",       "size": 4, "value": 0x3FC00000,             "asm": r"fsw\s+fs0"},
        {"label": "f32_min_out",         "size": 4, "value": 0x3FC00000,             "asm": r"fsw\s+fs1"},
        {"label": "f32_max_out",         "size": 4, "value": 0x40400000,             "asm": r"fsw\s+fa0"},
        {"label": "f32_iwu_out",         "size": 4, "value": 0x00000003,             "asm": r"sw\s+t6,0\(t2\)"},
        {"label": "f32_wu_back_out",     "size": 4, "value": 0x40400000,             "asm": r"fsw\s+fa6"},
        {"label": "f32_feq_out",         "size": 4, "value": 0x00000001,             "asm": r"sw\s+t0,0\(t2\)"},
        {"label": "f32_flt_out",         "size": 4, "value": 0x00000001,             "asm": r"sw\s+t1,0\(t2\)"},
        {"label": "f32_fle_out",         "size": 4, "value": 0x00000001,             "asm": r"sw\s+t2,0\(t3\)"},
        {"label": "f32_fclass_out",      "size": 4, "value": 0x00000040,             "asm": r"sw\s+t3,0\(t4\)"},
        {"label": "f64_out",             "size": 8, "value": 0x4008000000000000,      "asm": r"fsd\s+ft3"},
        {"label": "f64_i_out",           "size": 4, "value": 0x00000003,             "asm": r"sw\s+t3,0\(t2\)"},
        {"label": "f64_cvt_back_out",    "size": 8, "value": 0x4008000000000000,      "asm": r"fsd\s+ft4"},
        {"label": "f32_fnmadd_out",      "size": 4, "value": 0xF7FF839C,             "asm": r"fsw\s+fs6,0\(t2\)"},
        {"label": "f64_fmax_out",        "size": 8, "value": 0x7FF8000000000000,      "asm": r"fsd\s+fs3,0\(t2\)"},
        {"label": "f32_from_x_out",      "size": 4, "value": 0x3F800000,             "asm": r"fsw\s+fa1"},
        {"label": "f32_from_x_mirror_out","size": 4, "value": 0x3F800000,             "asm": r"sw\s+t6,0\(t2\)"},
        {"label": "tohost",              "size": 4, "value": 0x00000000,             "asm": r"sw\s+t0,0\(t1\)"},
    ]

def verify_fregs(freg_entries, pcs):
    failures = []
    has_64 = any(entry["hexlen"] >= 16 for entry in freg_entries)
    if has_64:
        box32 = lambda x: (0xFFFFFFFF << 32) | x
        expected = [
            (0,  box32(0x3FC00000),           64, "flw_ft0"),
            (1,  box32(0x40400000),           64, "fadd_s_ft1"),
            (2,  box32(0x3FC00000),           64, "fsub_s_ft2"),
            (3,  box32(0x40100000),           64, "fmul_s_ft3"),
            (4,  box32(0x40000000),           64, "fdiv_s_ft4"),
            (5,  box32(0x40400000),           64, "fcvt_s_w_ft5"),
            (6,  box32(0x3FC00000),           64, "fmv_s_ft6"),
            (7,  box32(0xBFC00000),           64, "fneg_s_ft7"),
            (8,  box32(0x3FC00000),           64, "fabs_s_fs0"),
            (9,  box32(0x3FC00000),           64, "fmin_s_fs1"),
            (10, box32(0x40400000),           64, "fmax_s_fa0"),
            (2,  0x3FF8000000000000,          64, "fld_ft2"),
            (3,  0x4008000000000000,          64, "fadd_d_ft3"),
            (4,  0x4008000000000000,          64, "fcvt_d_w_ft4"),
            (11, box32(0x3F800000),           64, None),
            (12, box32(0x40700000),           64, "fmadd_s_fa2"),
            (13, box32(0xBF400000),           64, "fnmsub_s_fa3"),
            (14, box32(0x40C00000),           64, "fmadd_s_fa4"),
            (15, box32(0x40400000),           64, "fmsub_s_fa5"),
            (16, box32(0x40400000),           64, "fcvt_s_wu_fa6"),
            (22, box32(0xF7FF839C),           64, "fnmadd_s_fs6"),
            (18, 0x4002000000000000,          64, "fmul_d_fs2"),
            (19, 0x400E000000000000,          64, None),
            (20, 0x4008000000000000,          64, None),
            (21, 0x3FF8000000000000,          64, None),
            (19, 0x7FF8000000000000,          64, "fmax_d_fs3"),
        ]
    else:
        expected = [
            (0,  0x3FC00000,                   32, "flw_ft0"),
            (1,  0x40400000,                   32, "fadd_s_ft1"),
            (2,  0x3FC00000,                   32, "fsub_s_ft2"),
            (3,  0x40100000,                   32, "fmul_s_ft3"),
            (4,  0x40000000,                   32, "fdiv_s_ft4"),
            (5,  0x40400000,                   32, "fcvt_s_w_ft5"),
            (6,  0x3FC00000,                   32, "fmv_s_ft6"),
            (7,  0xBFC00000,                   32, "fneg_s_ft7"),
            (8,  0x3FC00000,                   32, "fabs_s_fs0"),
            (9,  0x3FC00000,                   32, "fmin_s_fs1"),
            (10, 0x40400000,                   32, "fmax_s_fa0"),
            (2,  0x3FF8000000000000,           64, "fld_ft2"),
            (3,  0x4008000000000000,           64, "fadd_d_ft3"),
            (4,  0x4008000000000000,           64, "fcvt_d_w_ft4"),
            (11, 0x3F800000,                   32, None),
            (12, 0x40700000,                   32, "fmadd_s_fa2"),
            (13, 0xBF400000,                   32, "fnmsub_s_fa3"),
            (14, 0x40C00000,                   32, "fmadd_s_fa4"),
            (15, 0x40400000,                   32, "fmsub_s_fa5"),
            (16, 0x40400000,                   32, "fcvt_s_wu_fa6"),
            (22, 0xF7FF839C,                   32, "fnmadd_s_fs6"),
            (18, 0x4002000000000000,           64, "fmul_d_fs2"),
            (19, 0x400E000000000000,           64, None),
            (20, 0x4008000000000000,           64, None),
            (21, 0x3FF8000000000000,           64, None),
            (19, 0x7FF8000000000000,           64, "fmax_d_fs3"),
        ]

    for rd, val, bits, key in expected:
        pc = pcs.get(key) if key else None
        if key and pc is None:
            failures.append(f"[freg] Missing ASM PC for {key}")
            continue
        match = find_fwrite(freg_entries, rd, val, bits, None)
        if not match:
            if pc is None:
                base = f"[freg] Missing f[{rd}] = 0x{val:0{bits//4}X}"
            else:
                base = f"[freg] Missing f[{rd}] = 0x{val:0{bits//4}X} (expected PC 0x{pc:08X})"
            candidates = matching_entries(freg_entries, rd, bits)
            if candidates:
                observed = ", ".join(
                    f"0x{entry['val']:0{bits//4}X}@0x{entry['pc']:08X}" for entry in candidates[:3]
                )
                if len(candidates) > 3:
                    observed += ", ..."
                failures.append(f"{base}; observed {observed}")
            else:
                failures.append(base)
    return failures

def verify_mem(mem_entries, asm_lookup, symbols):
    failures = []
    expected = expected_mem_sequence()
    if not mem_entries:
        failures.append("[mem] run.memTrace missing or empty")
        return failures
    if len(mem_entries) != len(expected):
        failures.append(f"[mem] Expected {len(expected)} writes but captured {len(mem_entries)}")
        return failures
    for idx, (entry, spec) in enumerate(zip(mem_entries, expected), start=1):
        target = symbols.get(spec["label"])
        if target is None:
            failures.append(f"[mem] Symbol {spec['label']} not found via nm")
            continue
        if entry["addr"] != target:
            failures.append(f"[mem] #{idx}: address 0x{entry['addr']:08X} != {spec['label']}@0x{target:08X}")
        if entry["size"] != spec["size"]:
            failures.append(f"[mem] #{idx}: size {entry['size']} != {spec['size']} for {spec['label']}")
        if entry["value"] != spec["value"]:
            failures.append(f"[mem] #{idx}: value 0x{entry['value']:X} != 0x{spec['value']:X} at {spec['label']}")
        asm_line = asm_lookup.get(entry["pc"])
        if asm_line is None:
            failures.append(f"[mem] #{idx}: no asm line for PC 0x{entry['pc']:08X}")
        elif not re.search(spec["asm"], asm_line):
            failures.append(f"[mem] #{idx}: PC 0x{entry['pc']:08X} line '{asm_line}' mismatched /{spec['asm']}/")
    return failures


def expected_exceptions_from_asm(asm_path):
    patterns = [
        ("ecall", 11, re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+ecall\b")),
        ("lw_misaligned", 4, re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+lw\s+t4,1\(t2\)")),
        ("illegal_insn", 2, re.compile(r"^\s*([0-9a-fA-F]{8}):\s+[0-9a-fA-F]+\s+\.word\s+0xffffffff")),
    ]

    expected = []
    seen = {name: False for (name, _, _) in patterns}

    with asm_path.open('r', errors='ignore') as f:
        for line in f:
            for name, cause, regex in patterns:
                if seen[name]:
                    continue
                m = regex.match(line)
                if m:
                    expected.append({
                        "label": name,
                        "pc": int(m.group(1), 16),
                        "cause": cause,
                    })
                    seen[name] = True
                    break

    missing = [name for (name, _, _) in patterns if not seen[name]]
    return expected, missing


def verify_exceptions(exc_entries, asm_path):
    failures = []
    expected, missing = expected_exceptions_from_asm(asm_path)

    for name in missing:
        failures.append(f"[exc] Missing expected trap site for {name} in {asm_path.name}")

    if not expected:
        return failures

    if not exc_entries:
        failures.append("[exc] No EXC lines found in run.logTrace; ensure simulator emits exception logs")
        return failures

    for spec in expected:
        match = None
        for entry in exc_entries:
            if entry["pc"] == spec["pc"] and entry["cause"] == spec["cause"]:
                match = entry
                break
        if not match:
            same_pc = [e for e in exc_entries if e["pc"] == spec["pc"]]
            same_cause = [e for e in exc_entries if e["cause"] == spec["cause"]]
            base = f"[exc] Missing EXC pc=0x{spec['pc']:08X} cause={spec['cause']} ({spec['label']})"
            if same_pc:
                observed = ", ".join(str(e["cause"]) for e in same_pc[:3])
                base += f"; observed causes at that PC: {observed}"
            elif same_cause:
                observed = ", ".join(f"0x{e['pc']:08X}" for e in same_cause[:3])
                base += f"; observed PCs for that cause: {observed}"
            failures.append(base)

    return failures

def main():
    root = Path(__file__).resolve().parents[2]
    skiptrap_dir = Path(__file__).resolve().parent
    freg_path = root / "run.fregTrace"
    mem_path = root / "run.memTrace"
    log_path = root / "run.logTrace"
    asm_path = skiptrap_dir / "build" / "skiptrap.asm"
    elf_path = skiptrap_dir / "build" / "skiptrap.elf"

    if not asm_path.exists():
        print(f"ERROR: Missing {asm_path}")
        return 2

    freg_entries = parse_fregtrace(freg_path)
    mem_entries = parse_memtrace(mem_path)
    exc_entries = parse_exc_log(log_path)
    pcs = parse_asm_pcs(asm_path)
    asm_lookup = asm_map_by_pc(asm_path)
    symbols, sym_err = load_symbol_map(elf_path)

    failures = []
    if sym_err:
        failures.append(sym_err)

    failures.extend(verify_fregs(freg_entries, pcs))
    failures.extend(verify_mem(mem_entries, asm_lookup, symbols))
    failures.extend(verify_exceptions(exc_entries, asm_path))

    if failures:
        print("SKIPTRAP TRACE CHECK: FAIL")
        for msg in failures:
            print(" -", msg)
        if len(freg_entries) < 5:
            print(" [hint] fregTrace has very few entries; ensure simulator emits FP logs.")
        return 1

    print("SKIPTRAP TRACE CHECK: PASS")
    return 0

if __name__ == "__main__":
    sys.exit(main())
