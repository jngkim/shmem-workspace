#!/usr/bin/env python3
"""
take_diff.py — Python equivalent of take_diff.sh.

For every *.before.log in the target directory, finds the matching *.log
(the "after" snapshot), computes per-NIC deltas, writes a *.delta file,
then runs analyze_telemetry_delta.py to produce analysis.md.

When given a run directory (a directory whose subdirectories contain
*.before.log files), processes all subdirectories automatically.

Usage:
  take_diff.py [directory]

If directory is omitted, the current working directory is used.
"""

import sys
import os
import re
import subprocess
import argparse


# ---------------------------------------------------------------------------
# Snapshot parsing (mirrors cxi_telemetry_diff.sh logic)
# ---------------------------------------------------------------------------

def parse_snapshot(path):
    """Parse a telemetry snapshot file.

    Returns:
        header   : str  — first line (hostname banner)
        counters : list[str] — counter names in file order (deduped)
        vals     : dict[str, dict[str, int]]  — counter -> {nic -> value}
    """
    header = ''
    counters = []
    seen = set()
    vals = {}  # { counter: { nic: value } }
    current = None

    with open(path) as f:
        for i, line in enumerate(f):
            line = line.rstrip('\n')
            if i == 0:
                header = line
                continue
            # Counter header: "counter_name:"
            m = re.match(r'^([A-Za-z0-9_]+):$', line)
            if m:
                current = m.group(1)
                if current not in seen:
                    counters.append(current)
                    seen.add(current)
                vals.setdefault(current, {})
                continue
            # Per-NIC value: "  cxi0: 12345"
            m = re.match(r'^\s+(cxi\d+):\s*(\d+)', line)
            if m and current:
                vals[current][m.group(1)] = int(m.group(2))

    return header, counters, vals


# ---------------------------------------------------------------------------
# Delta computation
# ---------------------------------------------------------------------------

def compute_delta(before_path, after_path, out_path):
    """Compute after-minus-before deltas and write to out_path.

    Returns the path written, or raises on error.
    """
    bheader, b_counters, b_vals = parse_snapshot(before_path)
    _,       _,          a_vals = parse_snapshot(after_path)

    lines = [
        f'=== DELTA: {bheader} ===',
        f'=== before: {before_path}',
        f'=== after:  {after_path}',
        '',
    ]

    for counter in b_counters:
        lines.append(f'{counter}:')
        b_nics = b_vals.get(counter, {})
        a_nics = a_vals.get(counter, {})
        nics = sorted(b_nics.keys(), key=lambda n: int(re.sub(r'\D', '', n)))
        total = 0
        for nic in nics:
            b = b_nics.get(nic, 0)
            a = a_nics.get(nic, 0)
            delta = a - b
            total += delta
            lines.append(f'  {nic}: {delta}')
        lines.append(f'  total: {total}')

    content = '\n'.join(lines) + '\n'
    with open(out_path, 'w') as f:
        f.write(content)
    return out_path


# ---------------------------------------------------------------------------
# Delta file parsing (for cross-impl comparison)
# ---------------------------------------------------------------------------

def parse_delta_file(path):
    """Parse a .delta file (produced by compute_delta).

    Returns dict: counter -> {'total': int, 'cxi0': int, ...}
    """
    counters = {}
    current = None
    with open(path) as f:
        for line in f:
            line = line.rstrip('\n')
            m = re.match(r'^([A-Za-z0-9_]+):$', line)
            if m:
                current = m.group(1)
                counters.setdefault(current, {})
                continue
            m = re.match(r'^\s+(cxi\d+|total):\s*(-?\d+)', line)
            if m and current:
                counters[current][m.group(1)] = int(m.group(2))
    return counters


def load_subdir_totals(subdir):
    """Load all .delta files in subdir and return summed totals across all nodes.

    Returns dict: counter -> int (sum of 'total' across all delta files)
    """
    delta_files = sorted(
        os.path.join(subdir, f)
        for f in os.listdir(subdir)
        if f.endswith('.delta')
    )
    combined = {}
    for path in delta_files:
        cdata = parse_delta_file(path)
        for counter, vals in cdata.items():
            total = vals.get('total', 0)
            combined[counter] = combined.get(counter, 0) + total
    return combined


def _cv_from_subdir(subdir, counter):
    """Compute coefficient-of-variation % for a counter's per-NIC values
    summed across all delta files in subdir."""
    import math
    delta_files = sorted(
        os.path.join(subdir, f)
        for f in os.listdir(subdir)
        if f.endswith('.delta')
    )
    nic_totals = {}
    for path in delta_files:
        cdata = parse_delta_file(path)
        vals = cdata.get(counter, {})
        for k, v in vals.items():
            if k == 'total':
                continue
            nic_totals[k] = nic_totals.get(k, 0) + v
    vals = list(nic_totals.values())
    if not vals or sum(vals) == 0:
        return 0.0
    mean = sum(vals) / len(vals)
    if mean == 0:
        return 0.0
    return math.sqrt(sum((v - mean) ** 2 for v in vals) / len(vals)) / mean * 100


def _weighted_lat_bucket(totals):
    """Return weighted mean latency bucket from summed counter totals dict."""
    lat_keys = [k for k in totals if k.startswith('pct_req_rsp_latency_')]
    lat_total = sum(totals[k] for k in lat_keys)
    if lat_total == 0:
        return None
    wmean = sum(int(k.split('_')[-1]) * totals[k] for k in lat_keys) / lat_total
    return wmean


def _pct_diff(base, new):
    if base == 0:
        return 'N/A'
    d = (new - base) / base * 100
    sign = '+' if d >= 0 else ''
    return f'{sign}{d:.1f}%'


def _fmt_mb(n):
    return f'{n / 1e6:.2f} MB'


def _atu_hit_rate(totals):
    hits   = totals.get('atu_cache_hit_base_page_size_0', 0)
    misses = totals.get('atu_cache_miss_0', 0)
    denom  = hits + misses
    return hits / denom * 100 if denom else 0.0


def _small_pkt_pct(totals):
    """Fraction of TX packets that are ≤127 bytes."""
    small = totals.get('hni_tx_ok_64', 0) + totals.get('hni_tx_ok_65_to_127', 0)
    tx_buckets = [
        'hni_tx_ok_64', 'hni_tx_ok_65_to_127', 'hni_tx_ok_128_to_255',
        'hni_tx_ok_256_to_511', 'hni_tx_ok_512_to_1023', 'hni_tx_ok_1024_to_2047',
        'hni_tx_ok_4096_to_8191', 'hni_tx_ok_8192_to_max',
    ]
    total_pkts = sum(totals.get(k, 0) for k in tx_buckets)
    return small / total_pkts * 100 if total_pkts else 0.0


def _error_total(totals):
    error_keys = [
        'hni_llr_tx_replay_event', 'hni_llr_rx_replay_event',
        'hni_llr_tx_nack_ctl_os', 'hni_llr_rx_nack_ctl_os', 'hni_llr_tx_discard',
        'pct_rsp_err_rcvd', 'pct_rsp_dropped_timeout', 'pct_rsp_dropped_try',
        'pct_bad_seq_nacks', 'pct_no_trs_nacks',
        'ixe_rx_pkt_drop_pct', 'ixe_rx_pkt_drop_ixe_parser',
        'pct_retry_trs_put', 'mst_stalled_waiting_put_crdts',
    ]
    return sum(totals.get(k, 0) for k in error_keys)


# ---------------------------------------------------------------------------
# Cross-impl comparison
# ---------------------------------------------------------------------------

def compare_impl_deltas(run_dir, test_dirs):
    """Find sos/shmemx pairs among test_dirs, compare key telemetry metrics,
    and write telemetry_comparison.md to run_dir."""

    # Group subdirs by impl and bench-key (everything after the impl prefix)
    sos_dirs    = {}  # bench_key -> path
    shmemx_dirs = {}  # bench_key -> path

    impl_re = re.compile(r'^(sos|shmemx)\.(.+)$')
    for d in test_dirs:
        name = os.path.basename(d)
        m = impl_re.match(name)
        if not m:
            continue
        impl, key = m.group(1), m.group(2)
        if impl == 'sos':
            sos_dirs[key] = d
        else:
            shmemx_dirs[key] = d

    pairs = sorted(set(sos_dirs) & set(shmemx_dirs))
    if not pairs:
        return  # nothing to compare

    lines = []
    lines.append('# Telemetry Delta Comparison: sos vs shmemx')
    lines.append('')
    lines.append(f'**Run directory**: `{os.path.basename(run_dir)}`  ')
    lines.append('')
    lines.append('Key CXI telemetry counters summed across all nodes, comparing sos and shmemx '
                 'for the same benchmark and process count.')
    lines.append('')
    lines.append('> Δ column is relative to sos as baseline. '
                 'Negative Δ = shmemx is better for latency/error metrics; '
                 'positive Δ = shmemx is better for throughput metrics.')
    lines.append('')

    for key in pairs:
        sos_dir    = sos_dirs[key]
        shmemx_dir = shmemx_dirs[key]

        sos_t    = load_subdir_totals(sos_dir)
        shmemx_t = load_subdir_totals(shmemx_dir)

        if not sos_t or not shmemx_t:
            continue

        lines.append(f'## {key}')
        lines.append('')
        lines.append('| Metric | sos | shmemx | Δ |')
        lines.append('|---|---|---|---|')

        # AMO events
        sos_amo  = sos_t.get('ixe_disp_amo_events', 0)
        shmx_amo = shmemx_t.get('ixe_disp_amo_events', 0)
        lines.append(f'| AMO events (total) | {sos_amo:,} | {shmx_amo:,} '
                     f'| {_pct_diff(sos_amo, shmx_amo) if sos_amo else "—"} |')

        # AMO success rate
        def amo_ok_rate(t):
            ev = t.get('ixe_disp_amo_events', 0)
            ok = t.get('ixe_disp_lpe_amos_ok', 0)
            return f'{ok/ev*100:.1f}%' if ev else '—'
        lines.append(f'| AMO success rate | {amo_ok_rate(sos_t)} | {amo_ok_rate(shmemx_t)} | — |')

        # NIC imbalance CV
        sos_cv   = _cv_from_subdir(sos_dir,    'ixe_disp_amo_events')
        shmx_cv  = _cv_from_subdir(shmemx_dir, 'ixe_disp_amo_events')
        sos_cv_s  = f'{sos_cv:.1f}%'  if sos_amo  else '—'
        shmx_cv_s = f'{shmx_cv:.1f}%' if shmx_amo else '—'
        lines.append(f'| NIC imbalance CV (AMO) | {sos_cv_s} | {shmx_cv_s} | — |')

        # ATU hit rate
        sos_atu  = _atu_hit_rate(sos_t)
        shmx_atu = _atu_hit_rate(shmemx_t)
        lines.append(f'| ATU hit rate | {sos_atu:.1f}% | {shmx_atu:.1f}% '
                     f'| {_pct_diff(sos_atu, shmx_atu)} |')

        # TX / RX bytes
        sos_tx  = sos_t.get('hni_sts_tx_ok_octets', 0)
        shmx_tx = shmemx_t.get('hni_sts_tx_ok_octets', 0)
        sos_rx  = sos_t.get('hni_sts_rx_ok_octets', 0)
        shmx_rx = shmemx_t.get('hni_sts_rx_ok_octets', 0)
        lines.append(f'| TX bytes (all nodes) | {_fmt_mb(sos_tx)} | {_fmt_mb(shmx_tx)} '
                     f'| {_pct_diff(sos_tx, shmx_tx)} |')
        lines.append(f'| RX bytes (all nodes) | {_fmt_mb(sos_rx)} | {_fmt_mb(shmx_rx)} '
                     f'| {_pct_diff(sos_rx, shmx_rx)} |')

        # Small-packet fraction
        sos_sp  = _small_pkt_pct(sos_t)
        shmx_sp = _small_pkt_pct(shmemx_t)
        lines.append(f'| TX small pkts ≤127B | {sos_sp:.1f}% | {shmx_sp:.1f}% | — |')

        # Weighted latency bucket
        sos_lat  = _weighted_lat_bucket(sos_t)
        shmx_lat = _weighted_lat_bucket(shmemx_t)
        sos_lat_s  = f'{sos_lat:.2f}'  if sos_lat  is not None else '—'
        shmx_lat_s = f'{shmx_lat:.2f}' if shmx_lat is not None else '—'
        dlat = _pct_diff(sos_lat, shmx_lat) if sos_lat and shmx_lat else '—'
        lines.append(f'| Weighted latency bucket | {sos_lat_s} | {shmx_lat_s} | {dlat} |')

        # Fabric errors
        sos_err  = _error_total(sos_t)
        shmx_err = _error_total(shmemx_t)
        lines.append(f'| Fabric errors (total) | {sos_err:,} | {shmx_err:,} | — |')

        lines.append('')

    out_path = os.path.join(run_dir, 'telemetry_comparison.md')
    md = '\n'.join(lines)
    print(md)
    with open(out_path, 'w') as f:
        f.write(md)
    print(f'\nTelemetry comparison written to: {out_path}', file=sys.stderr)


# ---------------------------------------------------------------------------
# Directory helpers
# ---------------------------------------------------------------------------

def has_before_logs(directory):
    """Return True if the directory directly contains *.before.log files."""
    return any(f.endswith('.before.log') for f in os.listdir(directory))


def subdirs_with_before_logs(directory):
    """Return sorted list of immediate subdirectories that contain *.before.log files."""
    result = []
    for name in sorted(os.listdir(directory)):
        path = os.path.join(directory, name)
        if os.path.isdir(path) and has_before_logs(path):
            result.append(path)
    return result


# ---------------------------------------------------------------------------
# Per-directory processing
# ---------------------------------------------------------------------------

def process_directory(target_dir, analyze_script, no_analyze):
    """Run diffs (and optionally analysis) for a single test directory.

    Returns (ok_count, skipped_count).
    """
    before_logs = sorted(
        os.path.join(target_dir, f)
        for f in os.listdir(target_dir)
        if f.endswith('.before.log')
    )

    if not before_logs:
        print(f'  No *.before.log files found in: {target_dir}', file=sys.stderr)
        return 0, 0

    ok = 0
    skipped = 0

    for before in before_logs:
        stem  = before[:-len('.before.log')]
        after = stem + '.log'
        out   = stem + '.delta'

        if not os.path.isfile(after):
            print(f'  SKIP: after-log not found (expected {os.path.basename(after)})',
                  file=sys.stderr)
            skipped += 1
            continue

        bname = os.path.basename(before)
        aname = os.path.basename(after)
        print(f'  diff: {bname}  →  {aname}')

        try:
            compute_delta(before, after, out)
            print(f'  Delta written to: {out}', file=sys.stderr)
            ok += 1
        except Exception as exc:
            print(f'  ERROR computing delta for {before}: {exc}', file=sys.stderr)
            skipped += 1

    if ok > 0 and not no_analyze and analyze_script:
        print('  Running telemetry analysis...', file=sys.stderr)
        try:
            subprocess.run(
                [sys.executable, analyze_script, target_dir],
                check=True
            )
        except subprocess.CalledProcessError as exc:
            print(f'  WARNING: analysis failed: {exc}', file=sys.stderr)

    return ok, skipped


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='Batch-compute CXI telemetry before/after deltas and run analysis.'
    )
    parser.add_argument(
        'directory', nargs='?', default='.',
        help='Test directory or run directory containing test subdirectories '
             '(default: current directory)'
    )
    parser.add_argument(
        '--no-analyze', action='store_true',
        help='Skip running analyze_telemetry_delta.py after computing deltas'
    )
    args = parser.parse_args()

    target_dir = os.path.abspath(args.directory)
    if not os.path.isdir(target_dir):
        print(f'ERROR: directory not found: {target_dir}', file=sys.stderr)
        sys.exit(1)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    analyze_script = os.path.join(script_dir, 'analyze_telemetry_delta.py')
    if not os.path.isfile(analyze_script):
        print(f'WARNING: analyze_telemetry_delta.py not found at {analyze_script}',
              file=sys.stderr)
        analyze_script = None

    # Determine whether this is a single test dir or a run dir with subdirs.
    if has_before_logs(target_dir):
        # Single test directory.
        test_dirs = [target_dir]
    else:
        test_dirs = subdirs_with_before_logs(target_dir)
        if not test_dirs:
            print(f'No *.before.log files found in {target_dir} or its subdirectories.',
                  file=sys.stderr)
            sys.exit(0)

    total_ok = 0
    total_skipped = 0

    for d in test_dirs:
        rel = os.path.relpath(d, target_dir)
        label = rel if rel != '.' else os.path.basename(d)
        print(f'\n=== {label} ===')
        ok, skipped = process_directory(
            d, analyze_script if not args.no_analyze else None, args.no_analyze
        )
        total_ok += ok
        total_skipped += skipped

    print(f'\nTotal: {total_ok} delta(s) written, {total_skipped} skipped '
          f'across {len(test_dirs)} director{"ies" if len(test_dirs) != 1 else "y"}.',
          file=sys.stderr)

    # --- Cross-impl comparison (only for run dirs with multiple subdirs) ---
    if len(test_dirs) > 1 and not args.no_analyze:
        print('\nRunning cross-impl telemetry comparison...', file=sys.stderr)
        compare_impl_deltas(target_dir, test_dirs)


if __name__ == '__main__':
    main()
