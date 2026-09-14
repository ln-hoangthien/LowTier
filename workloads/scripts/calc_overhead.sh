#!/usr/bin/env python3
# ==============================================================================
# Script: calc_overhead.sh
# Location: workloads/scripts/calc_overhead.sh
# Description: Parses regression logs (regress_*.log) in workloads/output/<kernel>/
#              - Extracts 'Workload Execution Runtime' and handler total times.
#              - Supports tier ratios (e.g. 1:1, 1:2, 1:4, 1:8, 2:1, 4:1, 8:1).
#              - Computes p50, p90, p95, p99 percentiles for migrate_misplaced_page & intel_pmu_handle_irq.
#              - Generates Excel-ready CDF tables (TSV / CSV) for direct copy-pasting into Excel.
#
# Usage:
#   calc_overhead.sh [-r ratio] [-o output_summary] [kernel]
# ==============================================================================

import sys
import os
import glob
import re
import argparse
import subprocess
import collections

def shorten_kernel_name(k):
    """Shortens full kernel release strings to their friendly baseline names."""
    for name in ["Colloid-TPP-Alto", "Colloid-TPP", "Nomad-Alto", "Nomad", "Memtis", "HybridTier", "PACT", "TPP", "generic"]:
        if name.lower() in k.lower():
            return name
    cleaned = re.sub(r'^\d+\.\d+[\w\.\-]*?-(htmm-)?', '', k)
    return cleaned if cleaned else k

def normalize_ratio(r):
    """Normalizes ratio string to X:Y format, 'all', or 'default'."""
    if not r or r.lower() in ["all", "*"]:
        return "all"
    if r.lower() in ["default", "none"]:
        return "default"
    r = r.strip().lower()
    if r.startswith("ratio_"):
        r = r[6:]
    r = r.replace("_", ":")
    m = re.match(r"^(\d+):(\d+)$", r)
    if m:
        return f"{m.group(1)}:{m.group(2)}"
    return r

def ratio_sort_key(r):
    """Sort key for tier ratios: numerical ratio (e.g. 1:8 < 1:4 < 1:2 < 1:1 < 2:1 < 4:1 < 8:1), with 'default' first."""
    if r == "default" or ":" not in r:
        return (0, 0.0, r)
    try:
        parts = r.split(":")
        val = float(parts[0]) / float(parts[1])
        return (1, val, r)
    except Exception:
        return (2, 0.0, r)

def parse_stem(stem):
    """
    Parses a file stem (e.g. 'gapbs_bc_kron_1_1', 'xsbench_1_4', 'gapbs_sssp_kron')
    into (base_workload, ratio, stem).
    """
    m_ratio = re.search(r"[:_]([0-9]+)[:_]([0-9]+)$", stem)
    if m_ratio:
        base_part = stem[:m_ratio.start()]
        ratio = f"{m_ratio.group(1)}:{m_ratio.group(2)}"
    else:
        base_part = stem
        ratio = "default"
    
    # Standardize workload alias names (e.g. prkron -> pr_kron, bcroad -> bc_road)
    w_base = re.sub(r'^(gapbs_[a-z]+)(kron|twitter|urand|web|road)$', r'\1_\2', base_part)
    return w_base, ratio, stem

def extract_promoted_pages(content, kernel_name):
    """
    Extracts successfully promoted pages, volume (MB), candidate pages, and promotion bandwidth
    across diverse kernel tiering implementations (Nomad, TPP, Memtis, Colloid, Generic).
    """
    # 1. Nomad (Transactional and Async Promotion counters)
    m_tx = re.search(r"Transactional Promotions Succeeded\s*:\s*(\d+)", content)
    m_nomad = re.search(r"Successful Async Promotions \(success_nr\)\s*:\s*(\d+)", content)
    m_try = re.search(r"Total Promotion Candidates \(try_nr\)\s*:\s*(\d+)", content)
    m_bw = re.search(r"Average Promotion Bandwidth\s*:\s*([\d\.]+)\s*MB/s", content)

    if m_tx or m_nomad:
        pages = int(m_tx.group(1)) if m_tx else int(m_nomad.group(1))
        cand = int(m_try.group(1)) if m_try else None
        bw = float(m_bw.group(1)) if m_bw else None
        mb = round((pages * 4096) / (1024 * 1024), 2)
        return pages, mb, cand, bw

    # 2. Memtis (HTMM counter in /proc/vmstat report)
    m_mem = re.search(r"Promoted Pages \(htmm_nr_promoted\)\s*:\s*(\d+)(?:\s*\(([\d\.]+)\s*MB Promoted\))?", content)
    if m_mem:
        pages = int(m_mem.group(1))
        mb = float(m_mem.group(2)) if m_mem.group(2) else round((pages * 4096) / (1024 * 1024), 2)
        bw = float(m_bw.group(1)) if m_bw else None
        return pages, mb, None, bw

    # 3. TPP / Generic / Colloid Tiered Memory Summary
    m_tpp = re.search(r"Promoted Memory Volume\s*:\s*([\d\.]+)\s*MB\s*\((\d+)\s*pages\)", content)
    m_cand = re.search(r"Promotion Candidates \(pgpromote_cand\)\s*:\s*(\d+)", content)
    m_numa = re.search(r"NUMA Pages Migrated \(numa_pages_mig\)\s*:\s*(\d+)", content)
    m_mig = re.search(r"Total Migrated Pages Delta \(pgmigrate\)\s*:\s*(\d+)", content)
    m_bpf_mig = re.search(r"@numa_faults\[(?:migrate_misplaced_page|migrate_misplaced_folio)\]:\s*(\d+)", content)
    m_r = re.search(r"(?:Workload Execution Runtime|Application Runtime)\s*:\s*(\d+)", content)
    runtime = int(m_r.group(1)) if m_r and int(m_r.group(1)) > 0 else None

    cand = int(m_cand.group(1)) if m_cand else None
    if m_bpf_mig and int(m_bpf_mig.group(1)) > 0:
        bpf_cand = int(m_bpf_mig.group(1))
        if cand is None or bpf_cand > cand:
            cand = bpf_cand

    if m_tpp:
        mb = float(m_tpp.group(1))
        pages = int(m_tpp.group(2))
        bw = float(m_bw.group(1)) if m_bw else None

        # Sanity check: In run_with_stats.sh, when pgpromote_anon is 0 (e.g. Linux 6.x Colloid),
        # it falls back to pgmigrate_success. That counter includes all demotions by kswapd!
        # When pages == pgmigrate and NUMA Pages Migrated exists, use numa_pages_mig as actual promotions.
        if m_mig and pages == int(m_mig.group(1)) and m_numa and int(m_numa.group(1)) != pages:
            pages = int(m_numa.group(1))
            mb = round((pages * 4096) / (1024 * 1024), 2)
            if runtime:
                bw = round(mb / runtime, 2)

        if cand and pages > cand:
            if m_bpf_mig and int(m_bpf_mig.group(1)) >= pages:
                cand = int(m_bpf_mig.group(1))
            else:
                cand = pages

        return pages, mb, cand, bw

    # 4. Fallback if NUMA Pages Migrated exists (TPP, Generic, Colloid)
    if m_numa and int(m_numa.group(1)) > 0:
        pages = int(m_numa.group(1))
        mb = round((pages * 4096) / (1024 * 1024), 2)
        bw = round(mb / runtime, 2) if runtime else (float(m_bw.group(1)) if m_bw else None)
        if cand and pages > cand:
            if m_bpf_mig and int(m_bpf_mig.group(1)) >= pages:
                cand = int(m_bpf_mig.group(1))
            else:
                cand = pages
        return pages, mb, cand, bw

    # 5. Generic / Colloid fallback if pgmigrate is reported
    if m_mig and ("generic" in kernel_name.lower() or "colloid" in kernel_name.lower()):
        pages = int(m_mig.group(1))
        mb = round((pages * 4096) / (1024 * 1024), 2)
        bw = round(mb / runtime, 2) if runtime else (float(m_bw.group(1)) if m_bw else None)
        return pages, mb, cand, bw

    return 0, 0.0, None, None

def build_excel_promoted_pages_table(valid_kernels, all_workloads, all_ratios_by_workload, data):
    """Builds a TSV & CSV matrix of Workload + Ratio (rows) x Kernel (columns) for Promoted Pages."""
    headers = ["Workload", "Ratio"]
    for k in valid_kernels:
        headers.append(shorten_kernel_name(k))

    tsv_lines = ["\t".join(headers)]
    csv_lines = [",".join(headers)]

    for w in sorted(all_workloads):
        for r in sorted(all_ratios_by_workload[w], key=ratio_sort_key):
            row_tsv = [w, r]
            row_csv = [w, r]
            for k in valid_kernels:
                if (w, r) in data.get(k, {}):
                    val = str(data[k][(w, r)].get("promoted_pages", 0))
                else:
                    val = "-"
                row_tsv.append(val)
                row_csv.append(val)
            tsv_lines.append("\t".join(row_tsv))
            csv_lines.append(",".join(row_csv))

    return "\n".join(tsv_lines), "\n".join(csv_lines)

def parse_num(s):
    """Parses integers with K, M, G, T, P, E suffixes."""
    if s is None:
        return 0
    s = s.strip().upper()
    mult = 1
    if s.endswith("K"):
        mult = 1024
        s = s[:-1]
    elif s.endswith("M"):
        mult = 1024**2
        s = s[:-1]
    elif s.endswith("G"):
        mult = 1024**3
        s = s[:-1]
    elif s.endswith("T"):
        mult = 1024**4
        s = s[:-1]
    elif s.endswith("P"):
        mult = 1024**5
        s = s[:-1]
    elif s.endswith("E"):
        mult = 1024**6
        s = s[:-1]
    try:
        return int(float(s) * mult)
    except Exception:
        return 0

def parse_histogram(text, probe_name):
    """Extracts (low, high, count) buckets from bpftrace histogram output."""
    pattern = rf"@numa_page_latency_us\[{re.escape(probe_name)}\]:\s*\n"
    pos = re.search(pattern, text)
    if not pos:
        return []
    rest = text[pos.end():]
    buckets = []
    for line in rest.split("\n"):
        line = line.strip()
        if not line:
            if buckets: break
            continue
        if line.startswith("@") or line.startswith("="):
            break
        lm = re.match(r"^\[\s*([0-9A-Za-z]+)(?:\s*,\s*([0-9A-Za-z]+))?\s*[\)\]]\s+(\d+)", line)
        if lm:
            low_str = lm.group(1)
            high_str = lm.group(2)
            count = int(lm.group(3))
            if high_str is None:
                low = parse_num(low_str)
                high = low
            else:
                low = parse_num(low_str)
                high = parse_num(high_str)
            buckets.append((low, high, count))
    return buckets

def compute_percentiles(buckets, percentiles=[50, 90, 95, 99]):
    """Computes requested percentiles (us) via histogram linear interpolation."""
    total = sum(c for _, _, c in buckets)
    if total == 0:
        return {p: 0.0 for p in percentiles}
    res = {}
    for p in percentiles:
        target = (p / 100.0) * total
        cum = 0
        val = 0.0
        for low, high, count in buckets:
            if cum + count >= target:
                if low == high:
                    val = float(low)
                else:
                    fraction = (target - cum) / count
                    val = low + fraction * (high - low)
                break
            cum += count
        res[p] = val
    return res

def compute_cdf_at_cutoffs(buckets, cutoffs):
    """Returns {cutoff: cumulative_percentage} mapping."""
    total = sum(c for _, _, c in buckets)
    if total == 0:
        return {c: 0.0 for c in cutoffs}
    res = {}
    for cut in cutoffs:
        cum = 0
        for low, high, count in buckets:
            b_high = high if high > 0 else low
            if b_high <= cut:
                cum += count
        res[cut] = (cum / total) * 100.0
    return res

def process_perf_bandwidth_logs(output_base, valid_kernels, target_ratio="all"):
    csv_lines = ["Kernel,Workload,Ratio,Time(s),Local_DRAM(MB),Remote_DRAM(MB),migrate_misplaced_page,intel_pmu_handle_irq,migration_entry_wait"]
    for k in valid_kernels:
        k_dir = os.path.join(output_base, k)
        perf_logs = glob.glob(os.path.join(k_dir, "perf_bandwidth_*.log"))
        
        for p_log in sorted(perf_logs):
            raw_wname = re.sub(r"^perf_bandwidth_(.*)\.log$", r"\1", os.path.basename(p_log))
            w_base, ratio, _ = parse_stem(raw_wname)
            if target_ratio != "all" and ratio != target_ratio:
                continue
            k_label = shorten_kernel_name(k)
            
            time_map = {}
            try:
                with open(p_log, "r", errors="ignore") as fp:
                    for line in fp:
                        if line.startswith("#") or not line.strip():
                            continue
                        parts = line.split()
                        if len(parts) >= 3:
                            t_str = parts[0]
                            count_str = parts[1].replace(",", "")
                            event = parts[2]
                            
                            try:
                                count = int(count_str)
                            except ValueError:
                                count = 0
                                
                            if t_str not in time_map:
                                time_map[t_str] = {"local_dram": 0, "remote_dram": 0, "migrate_misplaced_page": 0, "intel_pmu_handle_irq": 0, "migration_entry_wait": 0}
                                
                            if event == "local_dram":
                                time_map[t_str]["local_dram"] = round((count * 64) / 1048576.0, 4)
                            elif event == "remote_dram":
                                time_map[t_str]["remote_dram"] = round((count * 64) / 1048576.0, 4)
                            elif event in ["probe:migrate_misplaced_page", "probe:migrate_misplaced_folio", "probe:decide_queue_page"]:
                                time_map[t_str]["migrate_misplaced_page"] = count
                            elif event == "probe:intel_pmu_handle_irq":
                                time_map[t_str]["intel_pmu_handle_irq"] = count
                            elif event in ["probe:migration_entry_wait", "probe:__migration_entry_wait", "probe:migration_entry_wait_huge", "probe:pmd_migration_entry_wait"]:
                                time_map[t_str]["migration_entry_wait"] = count
            except Exception:
                continue
                
            for t_str in sorted(time_map.keys(), key=lambda x: float(x) if x.replace('.','',1).isdigit() else 0):
                counts = time_map[t_str]
                csv_lines.append(f"{k_label},{w_base},{ratio},{t_str},{counts['local_dram']},{counts['remote_dram']},{counts['migrate_misplaced_page']},{counts['intel_pmu_handle_irq']},{counts['migration_entry_wait']}")
                
    return "\n".join(csv_lines)

def build_excel_cdf_table(valid_kernels, all_workloads, all_ratios_by_workload, data, probe_key):
    """Builds a tab-delimited (TSV) table mapping Latency_us rows to workload_ratio_kernel columns."""
    # Find all unique cutoff points
    all_cutoffs = set([0, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768])
    for k in valid_kernels:
        for w in all_workloads:
            for r in all_ratios_by_workload[w]:
                entry = data[k].get((w, r))
                if entry and f"{probe_key}_buckets" in entry:
                    for low, high, count in entry[f"{probe_key}_buckets"]:
                        all_cutoffs.add(high if high > 0 else low)

    sorted_cutoffs = sorted(list(all_cutoffs))

    # Pre-calculate CDF maps for each workload
    for k in valid_kernels:
        for w in all_workloads:
            for r in all_ratios_by_workload[w]:
                entry = data[k].get((w, r))
                if entry and f"{probe_key}_buckets" in entry:
                    entry[f"{probe_key}_cdf_map"] = compute_cdf_at_cutoffs(entry[f"{probe_key}_buckets"], sorted_cutoffs)

    # Columns: Latency(us) followed by <workload>[_<ratio>]_<kernel>
    series_keys = []
    headers = ["Latency(us)"]
    for w in sorted(all_workloads):
        for r in sorted(all_ratios_by_workload[w], key=ratio_sort_key):
            for k in valid_kernels:
                if (w, r) in data[k]:
                    k_label = shorten_kernel_name(k)
                    if r != "default":
                        col_name = f"{w}_{r.replace(':', '_')}_{k_label}"
                    else:
                        col_name = f"{w}_{k_label}"
                    series_keys.append((w, r, k, col_name))
                    headers.append(col_name)

    tsv_lines = ["\t".join(headers)]
    csv_lines = [",".join(headers)]

    for cut in sorted_cutoffs:
        row_vals_tsv = [str(cut)]
        row_vals_csv = [str(cut)]
        for w, r, k, _ in series_keys:
            cdf_map = data[k][(w, r)].get(f"{probe_key}_cdf_map", {})
            val = cdf_map.get(cut, 0.0)
            row_vals_tsv.append(f"{val:.2f}")
            row_vals_csv.append(f"{val:.2f}")
        tsv_lines.append("\t".join(row_vals_tsv))
        csv_lines.append(",".join(row_vals_csv))

    return "\n".join(tsv_lines), "\n".join(csv_lines)

def parse_perf_bandwidth_file(filepath):
    if not os.path.isfile(filepath):
        return None
    tot_local_lines = 0
    tot_remote_lines = 0
    sec_counts = {}
    try:
        with open(filepath, "r", errors="ignore") as f:
            for line in f:
                m = re.search(r"^\s*([\d\.]+)\s+([\d,]+)\s+([a-zA-Z0-9_:/]+)", line)
                if m:
                    ts = float(m.group(1))
                    val = int(m.group(2).replace(",", ""))
                    evt = m.group(3)
                    sec_idx = int(ts)
                    if sec_idx not in sec_counts:
                        sec_counts[sec_idx] = {"local": 0, "remote": 0}
                    if "local_dram" in evt or "data_reads" in evt:
                        tot_local_lines += val
                        sec_counts[sec_idx]["local"] += val
                    elif "remote_dram" in evt or "data_writes" in evt:
                        tot_remote_lines += val
                        sec_counts[sec_idx]["remote"] += val

        tot_local_gb = (tot_local_lines * 64) / (1024**3)
        tot_remote_gb = (tot_remote_lines * 64) / (1024**3)
        tot_gb = tot_local_gb + tot_remote_gb
        num_secs = len(sec_counts) if sec_counts else 1
        avg_local_bw_gbs = tot_local_gb / num_secs if num_secs > 0 else 0
        avg_remote_bw_gbs = tot_remote_gb / num_secs if num_secs > 0 else 0
        avg_bw_gbs = tot_gb / num_secs if num_secs > 0 else 0
        peak_sec_gbs = max([(s["local"] + s["remote"]) * 64 / (1024**3) for s in sec_counts.values()]) if sec_counts else 0

        return {
            "local_gb": tot_local_gb,
            "remote_gb": tot_remote_gb,
            "tot_gb": tot_gb,
            "avg_local_bw_gbs": avg_local_bw_gbs,
            "avg_remote_bw_gbs": avg_remote_bw_gbs,
            "avg_bw_gbs": avg_bw_gbs,
            "peak_bw_gbs": peak_sec_gbs,
        }
    except Exception:
        return None

def parse_pebs_wss_file(pebs_file):
    """Processes Hardware PEBS sampled virtual addresses to estimate WSS."""
    if not os.path.isfile(pebs_file):
        return None
    page_counts = collections.defaultdict(int)
    tot_samples = 0
    try:
        proc = subprocess.Popen(['perf', 'script', '-i', pebs_file, '-F', 'addr'],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        for line in proc.stdout:
            line = line.strip()
            if not line or line == "0":
                continue
            m = re.search(r'(?:0x)?([0-9a-fA-F]{6,16})', line)
            if m:
                try:
                    addr = int(m.group(1), 16)
                    if addr > 0x10000:
                        pfn = addr >> 12  # 4KB Page Frame Number
                        page_counts[pfn] += 1
                        tot_samples += 1
                except ValueError:
                    continue
        proc.wait()

        unique_pages = len(page_counts)
        sampled_wss_gb = (unique_pages * 4096) / (1024**3)

        # Chao1 / Good-Turing unseen page estimator
        f1 = sum(1 for c in page_counts.values() if c == 1)
        f2 = sum(1 for c in page_counts.values() if c == 2)
        if f2 > 0:
            est_unseen = (f1 * f1) / (2.0 * f2)
        else:
            est_unseen = f1
        est_total_pages = unique_pages + est_unseen
        est_wss_gb = (est_total_pages * 4096) / (1024**3)

        return {
            "tot_samples": tot_samples,
            "unique_pages": unique_pages,
            "sampled_wss_gb": sampled_wss_gb,
            "est_wss_gb": est_wss_gb
        }
    except Exception:
        return None

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    root_dir = os.path.abspath(os.path.join(script_dir, "../.."))
    output_base = os.path.join(root_dir, "workloads/output")
    summary_dir = os.path.join(output_base, "summary")
    try:
        os.makedirs(summary_dir, exist_ok=True)
    except Exception:
        pass

    parser = argparse.ArgumentParser(description="Calculate NUMA overheads, latency percentiles, and Excel-ready CDF tables.")
    parser.add_argument("kernel", nargs="?", default="all",
                        help="Specific kernel to analyze or 'all' (default: all)")
    parser.add_argument("-r", "--ratio", default="all",
                        help="Tier ratio to analyze (e.g., '1:1', '1:2', '1:4', '1:8', '2:1', '4:1', '8:1', 'all') (default: all)")
    parser.add_argument("-o", "--output", default=None,
                        help="Path to save the comparison summary table")
    args = parser.parse_args()

    target_ratio = normalize_ratio(args.ratio)
    ratio_suffix = f"_{target_ratio.replace(':', '_')}" if target_ratio != "all" else ""

    if not os.path.isdir(output_base):
        print(f"Error: Output base directory not found at: {output_base}")
        sys.exit(1)

    kernels = sorted([d for d in os.listdir(output_base) if os.path.isdir(os.path.join(output_base, d)) and d not in ["summary", "archive"] and not d.startswith(".") and not "_bk" in d and not "_backup" in d])
    if args.kernel and args.kernel.lower() != "all":
        kernels = [d for d in kernels if args.kernel.lower() in d.lower()]
    valid_kernels = []
    data = {}
    all_workloads = set()
    all_ratios_by_workload = collections.defaultdict(set)

    for k in kernels:
        k_dir = os.path.join(output_base, k)
        try:
            k_files = os.listdir(k_dir)
        except Exception:
            continue

        workload_stems = collections.defaultdict(set)
        for f in k_files:
            m_name = re.match(r"^(?:regress_|bpftrace_numa_page_|perf_bandwidth_|pebs_wss_)(.*?)(?:\.log|\.data)$", f)
            if m_name:
                raw_stem = m_name.group(1)
                w_base, ratio, _ = parse_stem(raw_stem)
                if target_ratio != "all" and ratio != target_ratio:
                    continue
                workload_stems[(w_base, ratio)].add(raw_stem)

        if not workload_stems:
            continue

        valid_kernels.append(k)
        data[k] = {}

        for (w_base, ratio) in sorted(workload_stems.keys(), key=lambda x: (x[0], ratio_sort_key(x[1]))):
            all_workloads.add(w_base)
            all_ratios_by_workload[w_base].add(ratio)

            found_stems = list(workload_stems[(w_base, ratio)])
            r_tags = [ratio.replace(":", "_"), ratio] if ratio != "default" else [""]
            base_vars = [
                w_base,
                re.sub(r'_(kron|urand|twitter|web|road)', r'\1', w_base),
                w_base.replace("streamhot", "stream_hot"),
                w_base.replace("stream_hot", "streamhot"),
                w_base.replace("_", "")
            ]
            cand_stems = found_stems + [
                f"{bv}_{rt}" if rt else bv
                for bv in base_vars
                for rt in r_tags
            ]
            seen = set()
            cand_stems = [s for s in cand_stems if not (s in seen or seen.add(s))]

            content = ""
            for cs in cand_stems:
                reg_path = os.path.join(k_dir, f"regress_{cs}.log")
                if os.path.isfile(reg_path):
                    try:
                        with open(reg_path, "r", errors="ignore") as fp:
                            c = fp.read()
                            if c.strip():
                                content = c
                                break
                    except Exception:
                        pass

            if "@total_time_us" not in content:
                for cs in cand_stems:
                    bpf_path = os.path.join(k_dir, f"bpftrace_numa_page_{cs}.log")
                    if os.path.isfile(bpf_path):
                        try:
                            with open(bpf_path, "r", errors="ignore") as fp:
                                content += "\n" + fp.read()
                                break
                        except Exception:
                            pass

            m_r = re.search(r"(?:Workload Execution Runtime|Application Runtime)\s*:\s*(\d+)", content)
            if not m_r:
                m_gnu = re.search(r"Elapsed \(wall clock\) time [^:]*:\s*(?:(\d+):)?(\d+):([\d\.]+)", content)
                if m_gnu:
                    hrs = int(m_gnu.group(1)) if m_gnu.group(1) else 0
                    mins = int(m_gnu.group(2))
                    secs = float(m_gnu.group(3))
                    runtime = int(hrs * 3600 + mins * 60 + round(secs))
                else:
                    runtime = 0
            else:
                runtime = int(m_r.group(1))

            m_mig = re.search(r"@total_time_us\[(?:migrate_misplaced_page|migrate_misplaced_folio)\]:\s*(\d+)", content)
            m_decide = re.search(r"@total_time_us\[decide_queue_page\]:\s*(\d+)", content)
            m_pmu = re.search(r"@total_time_us\[intel_pmu_handle_irq\]:\s*(\d+)", content)
            m_wait = re.search(r"@total_time_us\[(?:migration_entry_wait|__migration_entry_wait)\]:\s*(\d+)", content)
            m_wait_huge = re.search(r"@total_time_us\[(?:migration_entry_wait_huge|pmd_migration_entry_wait)\]:\s*(\d+)", content)
            m_rss = re.search(r"Peak Resident Set Size[^\:]*:\s*([\d\.]+)\s*GB", content)
            m_time_rss = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", content)
            m_pebs_wss = re.search(r"Estimated Total Working Set \(WSS\)\s*:\s*([\d\.]+)\s*GB", content) or \
                         re.search(r"Sampled Active Working Set \(WSS\)\s*:\s*([\d\.]+)\s*GB", content)

            # Extract successfully promoted pages across all kernel architectures
            prom_pages, prom_mb, prom_cand, prom_bw = extract_promoted_pages(content, k)

            if m_mig:
                mig = int(m_mig.group(1))
            elif m_decide:
                mig = int(m_decide.group(1))
            else:
                mig = 0

            pmu = int(m_pmu.group(1)) if m_pmu else 0
            mig_wait = int(m_wait.group(1)) if m_wait else 0
            mig_wait_huge = int(m_wait_huge.group(1)) if m_wait_huge else 0

            if m_rss:
                rss_gb = float(m_rss.group(1))
            elif m_time_rss:
                rss_gb = round(int(m_time_rss.group(1)) / (1024 * 1024), 2)
            else:
                rss_gb = None

            # Parse perf bandwidth file for DRAM traffic
            perf_info = None
            for cs in cand_stems:
                cand_path = os.path.join(k_dir, f"perf_bandwidth_{cs}.log")
                if os.path.isfile(cand_path):
                    perf_info = parse_perf_bandwidth_file(cand_path)
                    if perf_info:
                        break

            # If runtime not in regress log, fallback to perf stat duration
            if runtime == 0 and perf_info and perf_info.get("avg_bw_gbs", 0) > 0 and perf_info.get("tot_gb", 0) > 0:
                runtime = int(perf_info["tot_gb"] / perf_info["avg_bw_gbs"])

            # Parse PEBS WSS data file if present
            pebs_info = None
            for cs in cand_stems:
                pebs_path = os.path.join(k_dir, f"pebs_wss_{cs}.data")
                if os.path.isfile(pebs_path):
                    pebs_info = parse_pebs_wss_file(pebs_path)
                    if pebs_info:
                        break

            if pebs_info and pebs_info.get("est_wss_gb", 0) > 0:
                wss_gb = pebs_info["est_wss_gb"]
            elif m_pebs_wss:
                wss_gb = float(m_pebs_wss.group(1))
            else:
                wss_gb = None

            # Parse Histograms (support migrate_misplaced_page / migrate_misplaced_folio or decide_queue_page for Nomad)
            mig_buckets = parse_histogram(content, "migrate_misplaced_page")
            if not mig_buckets:
                mig_buckets = parse_histogram(content, "migrate_misplaced_folio")
            if not mig_buckets:
                mig_buckets = parse_histogram(content, "decide_queue_page")
            pmu_buckets = parse_histogram(content, "intel_pmu_handle_irq")

            # Parse migration_entry_wait histograms (Async migration collision wait)
            mig_wait_buckets = parse_histogram(content, "migration_entry_wait") or parse_histogram(content, "__migration_entry_wait") or []
            mig_wait_huge_b = parse_histogram(content, "migration_entry_wait_huge") or parse_histogram(content, "pmd_migration_entry_wait") or []
            all_wait_buckets = mig_wait_buckets + mig_wait_huge_b

            mig_pctiles = compute_percentiles(mig_buckets)
            pmu_pctiles = compute_percentiles(pmu_buckets)
            mig_wait_pctiles = compute_percentiles(all_wait_buckets)

            if runtime > 0:
                rus = runtime * 1000000
                # Filter out any BPF unsigned timestamp underflows
                if mig > rus * 64 and mig_buckets:
                    mig = int(sum(((low + high) / 2.0) * cnt for low, high, cnt in mig_buckets if high <= 10000000))
                if pmu > rus * 64 and pmu_buckets:
                    pmu = int(sum(((low + high) / 2.0) * cnt for low, high, cnt in pmu_buckets if high <= 10000000))
                if mig_wait > rus * 64 and mig_wait_buckets:
                    mig_wait = int(sum(((low + high) / 2.0) * cnt for low, high, cnt in mig_wait_buckets if high <= 10000000))
                if mig_wait_huge > rus * 64 and mig_wait_huge_b:
                    mig_wait_huge = int(sum(((low + high) / 2.0) * cnt for low, high, cnt in mig_wait_huge_b if high <= 10000000))

                tot_us = mig + pmu + mig_wait + mig_wait_huge
                data[k][(w_base, ratio)] = {
                    "runtime": runtime,
                    "rss_gb": rss_gb,
                    "wss_gb": wss_gb,
                    "promoted_pages": prom_pages,
                    "promoted_mb": prom_mb,
                    "prom_cand": prom_cand,
                    "prom_bw_mbs": prom_bw,
                    "mig_us": mig,
                    "pmu_us": pmu,
                    "mig_wait_us": mig_wait,
                    "mig_wait_huge_us": mig_wait_huge,
                    "tot_us": tot_us,
                    "mig_pct": (mig / rus) * 100,
                    "pmu_pct": (pmu / rus) * 100,
                    "mig_wait_pct": (mig_wait / rus) * 100,
                    "mig_wait_huge_pct": (mig_wait_huge / rus) * 100,
                    "tot_pct": (tot_us / rus) * 100,
                    "mig_pctiles": mig_pctiles,
                    "pmu_pctiles": pmu_pctiles,
                    "mig_wait_pctiles": mig_wait_pctiles,
                    "mig_buckets": mig_buckets,
                    "pmu_buckets": pmu_buckets,
                    "mig_wait_buckets": all_wait_buckets,
                    "perf_info": perf_info
                }

    if not valid_kernels:
        filter_msg = f" for ratio '{target_ratio}'" if target_ratio != "all" else ""
        print(f"No regression logs found{filter_msg} in any kernel directory under '{output_base}'.")
        sys.exit(0)

    lines = []

    # 1. OVERHEAD COMPARISON TABLE
    header1 = f"{'Workload':<25} {'Ratio':<8} {'Kernel':<20} {'Runtime(s)':>12} {'RSS(GB)':>10} {'WSS(GB)':>10} {'Promoted_Pages':>16} {'Handler_Time(us)':>18} {'migrate_page(%)':>17} {'migration_entry_wait(%)':>26} {'migration_entry_wait_huge(%)':>31} {'pmu_irq(%)':>14} {'Handler_Overhead(%)':>22}"
    b1 = len(header1)

    lines.append("=" * b1)
    lines.append("MULTI-KERNEL NUMA OVERHEAD & RUNTIME COMPARISON (%)".center(b1))
    lines.append("=" * b1)
    lines.append(header1)
    lines.append("-" * b1)

    for w in sorted(all_workloads):
        first_w = True
        for r in sorted(all_ratios_by_workload[w], key=ratio_sort_key):
            first_r = True
            for k in valid_kernels:
                if (w, r) in data[k]:
                    d = data[k][(w, r)]
                    w_label = w if first_w else ""
                    r_label = r if first_r else ""
                    k_label = shorten_kernel_name(k)
                    rss_s = f"{d['rss_gb']:.2f}" if d.get('rss_gb') is not None else "-"
                    wss_s = f"{d['wss_gb']:.2f}" if d.get('wss_gb') is not None else "-"
                    mig_s = f"{d['mig_pct']:.4f}%"
                    mig_wait_s = f"{d['mig_wait_pct']:.4f}%"
                    mig_wait_huge_s = f"{d['mig_wait_huge_pct']:.4f}%"
                    pmu_s = f"{d['pmu_pct']:.4f}%"
                    tot_s = f"{d['tot_pct']:.4f}%"
                    lines.append(f"{w_label:<25} {r_label:<8} {k_label:<20} {d['runtime']:>12d} {rss_s:>10} {wss_s:>10} {d['promoted_pages']:>16,d} {d['tot_us']:>18d} {mig_s:>17} {mig_wait_s:>26} {mig_wait_huge_s:>31} {pmu_s:>14} {tot_s:>22}")
                    first_w = False
                    first_r = False

    lines.append("=" * b1)
    lines.append("\n")

    # 2. MULTI-KERNEL MEMORY TIERING & PROMOTION SUMMARY TABLE
    header_prom = f"{'Workload':<25} {'Ratio':<8} {'Kernel':<20} {'Runtime(s)':>12} {'Promoted_Pages':>16} {'Promoted(MB)':>16} {'Promotion_BW(MB/s)':>20} {'Candidates':>16} {'Success_Rate(%)':>17}"
    bp = len(header_prom)

    lines.append("=" * bp)
    lines.append("MULTI-KERNEL MEMORY TIERING & PAGE PROMOTION SUMMARY".center(bp))
    lines.append("=" * bp)
    lines.append(header_prom)
    lines.append("-" * bp)

    for w in sorted(all_workloads):
        first_w = True
        for r in sorted(all_ratios_by_workload[w], key=ratio_sort_key):
            first_r = True
            for k in valid_kernels:
                if (w, r) in data[k]:
                    d = data[k][(w, r)]
                    w_label = w if first_w else ""
                    r_label = r if first_r else ""
                    k_label = shorten_kernel_name(k)
                    p_pages = d['promoted_pages']
                    p_mb = f"{d['promoted_mb']:.2f}"
                    p_bw = f"{d['prom_bw_mbs']:.2f}" if d.get('prom_bw_mbs') is not None else "-"
                    cand_s = f"{d['prom_cand']:,}" if d.get('prom_cand') is not None else "-"
                    if d.get('prom_cand') and d['prom_cand'] > 0:
                        rate = (p_pages / d['prom_cand']) * 100
                        if rate > 100.0:
                            rate = 100.0
                        succ_pct = f"{rate:.2f}%"
                    elif p_pages == 0:
                        succ_pct = "0.00%" if d.get('prom_cand') is not None else "-"
                    else:
                        succ_pct = "-"
                    lines.append(f"{w_label:<25} {r_label:<8} {k_label:<20} {d['runtime']:>12d} {p_pages:>16,d} {p_mb:>16} {p_bw:>20} {cand_s:>16} {succ_pct:>17}")
                    first_w = False
                    first_r = False

    lines.append("=" * bp)
    lines.append("\n")

    # 3. MIGRATE_MISPLACED_PAGE LATENCY PERCENTILES TABLE
    header2 = f"{'Workload':<25} {'Ratio':<8} {'Kernel':<20} {'p50 (us)':>12} {'p90 (us)':>12} {'p95 (us)':>12} {'p99 (us)':>12}"
    b2 = len(header2)

    lines.append("=" * b2)
    lines.append("LATENCY PERCENTILES: NUMA Fault Migration Handler (migrate_misplaced_page / decide_queue_page)".center(b2))
    lines.append("=" * b2)
    lines.append(header2)
    lines.append("-" * b2)

    for w in sorted(all_workloads):
        first_w = True
        for r in sorted(all_ratios_by_workload[w], key=ratio_sort_key):
            first_r = True
            for k in valid_kernels:
                if (w, r) in data[k]:
                    p = data[k][(w, r)]["mig_pctiles"]
                    w_label = w if first_w else ""
                    r_label = r if first_r else ""
                    k_label = shorten_kernel_name(k)
                    lines.append(f"{w_label:<25} {r_label:<8} {k_label:<20} {p[50]:>12.2f} {p[90]:>12.2f} {p[95]:>12.2f} {p[99]:>12.2f}")
                    first_w = False
                    first_r = False

    lines.append("=" * b2)
    lines.append("\n")

    # 4. INTEL_PMU_HANDLE_IRQ LATENCY PERCENTILES TABLE
    header3 = f"{'Workload':<25} {'Ratio':<8} {'Kernel':<20} {'p50 (us)':>12} {'p90 (us)':>12} {'p95 (us)':>12} {'p99 (us)':>12}"
    b3 = len(header3)

    lines.append("=" * b3)
    lines.append("LATENCY PERCENTILES: intel_pmu_handle_irq (PMI Interrupt Handler)".center(b3))
    lines.append("=" * b3)
    lines.append(header3)
    lines.append("-" * b3)

    for w in sorted(all_workloads):
        first_w = True
        for r in sorted(all_ratios_by_workload[w], key=ratio_sort_key):
            first_r = True
            for k in valid_kernels:
                if (w, r) in data[k]:
                    p = data[k][(w, r)]["pmu_pctiles"]
                    w_label = w if first_w else ""
                    r_label = r if first_r else ""
                    k_label = shorten_kernel_name(k)
                    lines.append(f"{w_label:<25} {r_label:<8} {k_label:<20} {p[50]:>12.2f} {p[90]:>12.2f} {p[95]:>12.2f} {p[99]:>12.2f}")
                    first_w = False
                    first_r = False

    lines.append("=" * b3)
    lines.append("\n")

    # 5. HARDWARE UNCORE DRAM BANDWIDTH & MEMORY TRAFFIC SUMMARY
    header4 = f"{'Workload':<25} {'Ratio':<8} {'Kernel':<20} {'Local_Traffic(GB)':>18} {'Remote_Traffic(GB)':>19} {'Total_Traffic(GB)':>18} {'Local_BW(GB/s)':>16} {'Remote_BW(GB/s)':>17} {'Total_BW(GB/s)':>16} {'Peak_BW(GB/s)':>15}"
    b4 = len(header4)

    lines.append("=" * b4)
    lines.append("MULTI-KERNEL HARDWARE UNCORE DRAM BANDWIDTH & MEMORY TRAFFIC SUMMARY".center(b4))
    lines.append("=" * b4)
    lines.append(header4)
    lines.append("-" * b4)

    for w in sorted(all_workloads):
        first_w = True
        for r in sorted(all_ratios_by_workload[w], key=ratio_sort_key):
            first_r = True
            for k in valid_kernels:
                if (w, r) in data[k]:
                    d = data[k][(w, r)]
                    w_label = w if first_w else ""
                    r_label = r if first_r else ""
                    k_label = shorten_kernel_name(k)
                    pinfo = d.get("perf_info")
                    if pinfo:
                        loc_s = f"{pinfo['local_gb']:.2f}"
                        rem_s = f"{pinfo['remote_gb']:.2f}"
                        tot_s = f"{pinfo['tot_gb']:.2f}"
                        loc_bw_s = f"{pinfo['avg_local_bw_gbs']:.2f}"
                        rem_bw_s = f"{pinfo['avg_remote_bw_gbs']:.2f}"
                        tot_bw_s = f"{pinfo['avg_bw_gbs']:.2f}"
                        peak_s = f"{pinfo['peak_bw_gbs']:.2f}"
                    else:
                        loc_s = rem_s = tot_s = loc_bw_s = rem_bw_s = tot_bw_s = peak_s = "-"
                    lines.append(f"{w_label:<25} {r_label:<8} {k_label:<20} {loc_s:>18} {rem_s:>19} {tot_s:>18} {loc_bw_s:>16} {rem_bw_s:>17} {tot_bw_s:>16} {peak_s:>15}")
                    first_w = False
                    first_r = False

    lines.append("=" * b4)
    lines.append("\n")

    # Build Excel Promoted Pages comparison table (TSV / CSV)
    prom_tsv, prom_csv = build_excel_promoted_pages_table(valid_kernels, all_workloads, all_ratios_by_workload, data)
    prom_csv_file = os.path.join(summary_dir, f"promoted_pages_comparison{ratio_suffix}.csv")
    try:
        with open(prom_csv_file, "w") as fp:
            fp.write(prom_csv + "\n")
        print(f"Saved Excel Promoted Pages CSV: {prom_csv_file}")
    except PermissionError:
        fallback_prom = f"/tmp/{os.path.basename(prom_csv_file)}"
        try:
            with open(fallback_prom, "w") as fp:
                fp.write(prom_csv + "\n")
            print(f"Saved Excel Promoted Pages CSV: {fallback_prom}")
        except Exception:
            pass
    except Exception as e:
        print(f"Error saving promoted pages CSV: {e}")

    # Build Excel CDF tables (TSV / CSV)
    mig_tsv, mig_csv = build_excel_cdf_table(valid_kernels, all_workloads, all_ratios_by_workload, data, "mig")
    pmu_tsv, pmu_csv = build_excel_cdf_table(valid_kernels, all_workloads, all_ratios_by_workload, data, "pmu")
    mig_wait_tsv, mig_wait_csv = build_excel_cdf_table(valid_kernels, all_workloads, all_ratios_by_workload, data, "mig_wait")

    # Save CSV files for Excel direct opening
    mig_csv_file = os.path.join(summary_dir, f"cdf_excel_migrate_misplaced_page{ratio_suffix}.csv")
    pmu_csv_file = os.path.join(summary_dir, f"cdf_excel_intel_pmu_handle_irq{ratio_suffix}.csv")
    mig_wait_csv_file = os.path.join(summary_dir, f"cdf_excel_migration_entry_wait{ratio_suffix}.csv")

    for fpath, content in [(mig_csv_file, mig_csv), (pmu_csv_file, pmu_csv), (mig_wait_csv_file, mig_wait_csv)]:
        try:
            with open(fpath, "w") as fp:
                fp.write(content + "\n")
        except PermissionError:
            fb = f"/tmp/{os.path.basename(fpath)}"
            try:
                with open(fb, "w") as fp:
                    fp.write(content + "\n")
            except Exception:
                pass

    # Append Excel copy-paste sections to summary
    lines.append("=" * 100)
    lines.append("EXCEL-READY TABLE (TSV): Successfully Promoted Pages (Copy & Paste below directly into Excel)")
    lines.append("=" * 100)
    lines.append(prom_tsv)
    lines.append("\n" + "=" * 100)
    lines.append("EXCEL-READY CDF TABLE (TSV): NUMA Page Fault Handler (migrate_misplaced_page / decide_queue_page)")
    lines.append("=" * 100)
    lines.append(mig_tsv)
    lines.append("\n" + "=" * 100)
    lines.append("EXCEL-READY CDF TABLE (TSV): intel_pmu_handle_irq (Copy & Paste below directly into Excel)")
    lines.append("=" * 100)
    lines.append(pmu_tsv)
    lines.append("\n" + "=" * 100)
    lines.append("EXCEL-READY CDF TABLE (TSV): migration_entry_wait (Async Migration Collision Wait)")
    lines.append("=" * 100)
    lines.append(mig_wait_tsv)

    output_text = "\n".join(lines)
    print(output_text)

    # Save summary table
    out_file = args.output if args.output else os.path.join(summary_dir, f"kernel_comparison_summary{ratio_suffix}.txt")
    try:
        with open(out_file, "w") as fp:
            fp.write(output_text + "\n")
        print(f"\nSaved comparison summary to: {out_file}")
    except PermissionError:
        fallback = f"/tmp/{os.path.basename(out_file)}"
        try:
            with open(fallback, "w") as fp:
                fp.write(output_text + "\n")
            print(f"\nSaved comparison summary to: {fallback}")
        except Exception:
            pass

    # Build Perf Bandwidth Time-Series
    perf_csv = process_perf_bandwidth_logs(output_base, valid_kernels, target_ratio)
    perf_csv_file = os.path.join(summary_dir, f"perf_bandwidth_timeseries{ratio_suffix}.csv")
    try:
        with open(perf_csv_file, "w") as fp:
            fp.write(perf_csv + "\n")
        print(f"Saved Excel Time-Series CSV (perf bandwidth): {perf_csv_file}")
    except PermissionError:
        fallback_csv = f"/tmp/{os.path.basename(perf_csv_file)}"
        try:
            with open(fallback_csv, "w") as fp:
                fp.write(perf_csv + "\n")
            print(f"Saved Excel Time-Series CSV (perf bandwidth): {fallback_csv}")
        except Exception as e:
            print(f"Error saving perf CSV: {e}")
    except Exception as e:
        print(f"Error: {e}")

    print(f"Saved Excel CDF CSV (migrate_page): {mig_csv_file}")
    print(f"Saved Excel CDF CSV (pmu_irq):      {pmu_csv_file}\n")

if __name__ == "__main__":
    main()
