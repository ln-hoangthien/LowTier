#!/usr/bin/env python3
# ==============================================================================
# Script: calc_overhead.sh
# Location: workloads/scripts/calc_overhead.sh
# Description: Parses regression logs (regress_*.log) in workloads/output/<kernel>/
#              - Extracts 'Workload Execution Runtime' and handler total times.
#              - Computes p50, p90, p95, p99 percentiles for migrate_misplaced_page & intel_pmu_handle_irq.
#              - Generates Excel-ready CDF tables (TSV / CSV) for direct copy-pasting into Excel.
#
# Usage:
#   calc_overhead.sh [-o output_summary]
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
    for name in ["Colloid-TPP-Alto", "Colloid-TPP", "Nomad-Noinline", "Nomad-Alto", "Nomad", "Memtis", "TPP", "generic"]:
        if name.lower() in k.lower():
            return name
    cleaned = re.sub(r'^\d+\.\d+[\w\.\-]*?-(htmm-)?', '', k)
    return cleaned if cleaned else k

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


def process_perf_bandwidth_logs(output_base, valid_kernels):
    csv_lines = ["Kernel,Workload,Time(s),Local_DRAM(MB),Remote_DRAM(MB),migrate_misplaced_page,intel_pmu_handle_irq"]
    for k in valid_kernels:
        k_dir = os.path.join(output_base, k)
        perf_logs = glob.glob(os.path.join(k_dir, "perf_bandwidth_*.log"))
        
        for p_log in sorted(perf_logs):
            wname = re.sub(r"^perf_bandwidth_(.*)\.log$", r"\1", os.path.basename(p_log))
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
                                time_map[t_str] = {"local_dram": 0, "remote_dram": 0, "migrate_misplaced_page": 0, "intel_pmu_handle_irq": 0}
                                
                            if event == "local_dram":
                                time_map[t_str]["local_dram"] = round((count * 64) / 1048576.0, 4)
                            elif event == "remote_dram":
                                time_map[t_str]["remote_dram"] = round((count * 64) / 1048576.0, 4)
                            elif event == "probe:migrate_misplaced_page":
                                time_map[t_str]["migrate_misplaced_page"] = count
                            elif event == "probe:intel_pmu_handle_irq":
                                time_map[t_str]["intel_pmu_handle_irq"] = count
            except Exception:
                continue
                
            for t_str in sorted(time_map.keys(), key=lambda x: float(x) if x.replace('.','',1).isdigit() else 0):
                counts = time_map[t_str]
                csv_lines.append(f"{k_label},{wname},{t_str},{counts['local_dram']},{counts['remote_dram']},{counts['migrate_misplaced_page']},{counts['intel_pmu_handle_irq']}")
                
    return "\n".join(csv_lines)


def build_excel_cdf_table(valid_kernels, all_workloads, data, probe_key):
    """Builds a tab-delimited (TSV) table mapping Latency_us rows to workload_kernel columns."""
    # Find all unique cutoff points
    all_cutoffs = set([0, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768])
    for k in valid_kernels:
        for w in all_workloads:
            if w in data[k] and f"{probe_key}_buckets" in data[k][w]:
                for low, high, count in data[k][w][f"{probe_key}_buckets"]:
                    all_cutoffs.add(high if high > 0 else low)

    sorted_cutoffs = sorted(list(all_cutoffs))

    # Pre-calculate CDF maps for each workload
    for k in valid_kernels:
        for w in all_workloads:
            if w in data[k] and f"{probe_key}_buckets" in data[k][w]:
                data[k][w][f"{probe_key}_cdf_map"] = compute_cdf_at_cutoffs(data[k][w][f"{probe_key}_buckets"], sorted_cutoffs)

    # Columns: Latency(us) followed by <workload>_<kernel>
    series_keys = []
    headers = ["Latency(us)"]
    for w in sorted(all_workloads):
        for k in valid_kernels:
            if w in data[k]:
                k_label = shorten_kernel_name(k)
                col_name = f"{w}_{k_label}"
                series_keys.append((w, k, col_name))
                headers.append(col_name)

    tsv_lines = ["\t".join(headers)]
    csv_lines = [",".join(headers)]

    for cut in sorted_cutoffs:
        row_vals_tsv = [str(cut)]
        row_vals_csv = [str(cut)]
        for w, k, _ in series_keys:
            cdf_map = data[k][w].get(f"{probe_key}_cdf_map", {})
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
    parser.add_argument("-o", "--output", default=os.path.join(summary_dir, "kernel_comparison_summary.txt"),
                        help="Path to save the comparison summary table")
    args = parser.parse_args()

    if not os.path.isdir(output_base):
        print(f"Error: Output base directory not found at: {output_base}")
        sys.exit(1)

    kernels = sorted([d for d in os.listdir(output_base) if os.path.isdir(os.path.join(output_base, d)) and d not in ["summary", "archive"] and not d.startswith(".") and not "_bk" in d and not "_backup" in d])
    valid_kernels = []
    data = {}
    all_workloads = set()

    for k in kernels:
        k_dir = os.path.join(output_base, k)
        try:
            k_files = os.listdir(k_dir)
        except Exception:
            continue

        wnames = set()
        for f in k_files:
            m_name = re.match(r"^(?:regress_|bpftrace_numa_page_|perf_bandwidth_|pebs_wss_)(.*?)(?:\.log|\.data)$", f)
            if m_name:
                w_candidate = m_name.group(1)
                # Standardize workload alias names (e.g. prkron -> pr_kron)
                w_std = re.sub(r'^(gapbs_[a-z]+)(kron|twitter|urand)$', r'\1_\2', w_candidate)
                wnames.add(w_std)

        if not wnames:
            continue

        valid_kernels.append(k)
        data[k] = {}

        for wname in sorted(wnames):
            all_workloads.add(wname)
            
            # Candidate file prefixes for matching
            cand_stems = [
                wname,
                wname.replace("_", ""),
                re.sub(r'_(kron|urand|twitter)', r'\1', wname),
                wname.replace("streamhot", "stream_hot"),
                wname.replace("stream_hot", "streamhot"),
            ]

            content = ""
            for cs in cand_stems:
                reg_path = os.path.join(k_dir, f"regress_{cs}.log")
                if os.path.isfile(reg_path):
                    try:
                        with open(reg_path, "r", errors="ignore") as fp:
                            c = fp.read()
                            if c.strip():
                                content = c + "\n" + content
                    except Exception:
                        pass
                bpf_path = os.path.join(k_dir, f"bpftrace_numa_page_{cs}.log")
                if os.path.isfile(bpf_path):
                    try:
                        with open(bpf_path, "r", errors="ignore") as fp:
                            content += "\n" + fp.read()
                    except Exception:
                        pass

            m_r = re.search(r"Workload Execution Runtime\s*:\s*(\d+)", content)
            m_mig = re.search(r"@total_time_us\[migrate_misplaced_page\]:\s*(\d+)", content)
            m_decide = re.search(r"@total_time_us\[decide_queue_page\]:\s*(\d+)", content)
            m_pmu = re.search(r"@total_time_us\[intel_pmu_handle_irq\]:\s*(\d+)", content)
            m_rss = re.search(r"Peak Resident Set Size[^\:]*:\s*([\d\.]+)\s*GB", content)
            m_time_rss = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", content)
            m_pebs_wss = re.search(r"Estimated Total Working Set \(WSS\)\s*:\s*([\d\.]+)\s*GB", content) or \
                         re.search(r"Sampled Active Working Set \(WSS\)\s*:\s*([\d\.]+)\s*GB", content)

            runtime = int(m_r.group(1)) if m_r else 0
            if m_mig:
                mig = int(m_mig.group(1))
            elif m_decide:
                mig = int(m_decide.group(1))
            else:
                mig = 0

            pmu = int(m_pmu.group(1)) if m_pmu else 0

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

            # Parse Histograms (support migrate_misplaced_page or decide_queue_page for Nomad)
            mig_buckets = parse_histogram(content, "migrate_misplaced_page")
            if not mig_buckets:
                mig_buckets = parse_histogram(content, "decide_queue_page")
            pmu_buckets = parse_histogram(content, "intel_pmu_handle_irq")

            mig_pctiles = compute_percentiles(mig_buckets)
            pmu_pctiles = compute_percentiles(pmu_buckets)

            if runtime > 0:
                rus = runtime * 1000000
                # Filter out any BPF unsigned timestamp underflows
                if mig > rus * 64 and mig_buckets:
                    mig = int(sum(((low + high) / 2.0) * cnt for low, high, cnt in mig_buckets if high <= 10000000))
                if pmu > rus * 64 and pmu_buckets:
                    pmu = int(sum(((low + high) / 2.0) * cnt for low, high, cnt in pmu_buckets if high <= 10000000))

                tot_us = mig + pmu
                data[k][wname] = {
                    "runtime": runtime,
                    "rss_gb": rss_gb,
                    "wss_gb": wss_gb,
                    "mig_us": mig,
                    "pmu_us": pmu,
                    "tot_us": tot_us,
                    "mig_pct": (mig / rus) * 100,
                    "pmu_pct": (pmu / rus) * 100,
                    "tot_pct": (tot_us / rus) * 100,
                    "mig_pctiles": mig_pctiles,
                    "pmu_pctiles": pmu_pctiles,
                    "mig_buckets": mig_buckets,
                    "pmu_buckets": pmu_buckets,
                    "perf_info": perf_info
                }

    if not valid_kernels:
        print(f"No regression logs found in any kernel directory under '{output_base}'.")
        sys.exit(0)

    lines = []

    # 1. OVERHEAD COMPARISON TABLE
    header1 = f"{'Workload':<25} {'Kernel':<20} {'Runtime(s)':>12} {'RSS(GB)':>10} {'WSS(GB)':>10} {'Handler_Time(us)':>18} {'migrate_page(%)':>17} {'pmu_irq(%)':>14} {'Handler_Overhead(%)':>22}"
    b1 = len(header1)

    lines.append("=" * b1)
    lines.append("MULTI-KERNEL NUMA OVERHEAD & RUNTIME COMPARISON (%)".center(b1))
    lines.append("=" * b1)
    lines.append(header1)
    lines.append("-" * b1)

    for w in sorted(all_workloads):
        first = True
        for k in valid_kernels:
            if w in data[k]:
                d = data[k][w]
                w_label = w if first else ""
                k_label = shorten_kernel_name(k)
                rss_s = f"{d['rss_gb']:.2f}" if d.get('rss_gb') is not None else "-"
                wss_s = f"{d['wss_gb']:.2f}" if d.get('wss_gb') is not None else "-"
                mig_s = f"{d['mig_pct']:.4f}%"
                pmu_s = f"{d['pmu_pct']:.4f}%"
                tot_s = f"{d['tot_pct']:.4f}%"
                lines.append(f"{w_label:<25} {k_label:<20} {d['runtime']:>12d} {rss_s:>10} {wss_s:>10} {d['tot_us']:>18d} {mig_s:>17} {pmu_s:>14} {tot_s:>22}")
                first = False

    lines.append("=" * b1)
    lines.append("\n")

    # 2. MIGRATE_MISPLACED_PAGE LATENCY PERCENTILES TABLE
    header2 = f"{'Workload':<25} {'Kernel':<20} {'p50 (us)':>12} {'p90 (us)':>12} {'p95 (us)':>12} {'p99 (us)':>12}"
    b2 = len(header2)

    lines.append("=" * b2)
    lines.append("LATENCY PERCENTILES: NUMA Fault Migration Handler (migrate_misplaced_page / decide_queue_page)".center(b2))
    lines.append("=" * b2)
    lines.append(header2)
    lines.append("-" * b2)

    for w in sorted(all_workloads):
        first = True
        for k in valid_kernels:
            if w in data[k]:
                p = data[k][w]["mig_pctiles"]
                w_label = w if first else ""
                k_label = shorten_kernel_name(k)
                lines.append(f"{w_label:<25} {k_label:<20} {p[50]:>12.2f} {p[90]:>12.2f} {p[95]:>12.2f} {p[99]:>12.2f}")
                first = False

    lines.append("=" * b2)
    lines.append("\n")

    # 3. INTEL_PMU_HANDLE_IRQ LATENCY PERCENTILES TABLE
    header3 = f"{'Workload':<25} {'Kernel':<20} {'p50 (us)':>12} {'p90 (us)':>12} {'p95 (us)':>12} {'p99 (us)':>12}"
    b3 = len(header3)

    lines.append("=" * b3)
    lines.append("LATENCY PERCENTILES: intel_pmu_handle_irq (PMI Interrupt Handler)".center(b3))
    lines.append("=" * b3)
    lines.append(header3)
    lines.append("-" * b3)

    for w in sorted(all_workloads):
        first = True
        for k in valid_kernels:
            if w in data[k]:
                p = data[k][w]["pmu_pctiles"]
                w_label = w if first else ""
                k_label = shorten_kernel_name(k)
                lines.append(f"{w_label:<25} {k_label:<20} {p[50]:>12.2f} {p[90]:>12.2f} {p[95]:>12.2f} {p[99]:>12.2f}")
                first = False

    lines.append("=" * b3)
    lines.append("\n")

    # 4. HARDWARE UNCORE DRAM BANDWIDTH & MEMORY TRAFFIC SUMMARY
    header4 = f"{'Workload':<25} {'Kernel':<20} {'Local_Traffic(GB)':>18} {'Remote_Traffic(GB)':>19} {'Total_Traffic(GB)':>18} {'Local_BW(GB/s)':>16} {'Remote_BW(GB/s)':>17} {'Total_BW(GB/s)':>16} {'Peak_BW(GB/s)':>15}"
    b4 = len(header4)

    lines.append("=" * b4)
    lines.append("MULTI-KERNEL HARDWARE UNCORE DRAM BANDWIDTH & MEMORY TRAFFIC SUMMARY".center(b4))
    lines.append("=" * b4)
    lines.append(header4)
    lines.append("-" * b4)

    for w in sorted(all_workloads):
        first = True
        for k in valid_kernels:
            if w in data[k]:
                d = data[k][w]
                w_label = w if first else ""
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
                lines.append(f"{w_label:<25} {k_label:<20} {loc_s:>18} {rem_s:>19} {tot_s:>18} {loc_bw_s:>16} {rem_bw_s:>17} {tot_bw_s:>16} {peak_s:>15}")
                first = False

    lines.append("=" * b4)
    lines.append("\n")

    # Build Excel CDF tables (TSV / CSV)
    mig_tsv, mig_csv = build_excel_cdf_table(valid_kernels, all_workloads, data, "mig")
    pmu_tsv, pmu_csv = build_excel_cdf_table(valid_kernels, all_workloads, data, "pmu")

    # Save CSV files for Excel direct opening
    mig_csv_file = os.path.join(summary_dir, "cdf_excel_migrate_misplaced_page.csv")
    pmu_csv_file = os.path.join(summary_dir, "cdf_excel_intel_pmu_handle_irq.csv")

    for fpath, content in [(mig_csv_file, mig_csv), (pmu_csv_file, pmu_csv)]:
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
    lines.append("EXCEL-READY CDF TABLE (TSV): NUMA Page Fault Handler (migrate_misplaced_page / decide_queue_page)")
    lines.append("=" * 100)
    lines.append(mig_tsv)
    lines.append("\n" + "=" * 100)
    lines.append("EXCEL-READY CDF TABLE (TSV): intel_pmu_handle_irq (Copy & Paste below directly into Excel)")
    lines.append("=" * 100)
    lines.append(pmu_tsv)

    output_text = "\n".join(lines)
    print(output_text)

    # Save summary table
    out_file = args.output
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
    perf_csv = process_perf_bandwidth_logs(output_base, valid_kernels)
    perf_csv_file = os.path.join(summary_dir, "perf_bandwidth_timeseries.csv")
    try:
        with open(perf_csv_file, "w") as fp:
            fp.write(perf_csv + "\n")
        print(f"Saved Excel Time-Series CSV (perf bandwidth): {perf_csv_file}")
    except PermissionError:
        fallback_csv = f"/tmp/perf_bandwidth_timeseries.csv"
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
