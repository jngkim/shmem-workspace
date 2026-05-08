#!/usr/bin/env python3
"""
analyze_telemetry_delta.py — Analyze CXI telemetry *.delta files and produce a Markdown report.

Usage:
  analyze_telemetry_delta.py <file.delta> [file.delta ...]
  analyze_telemetry_delta.py <directory>       # processes all *.delta files found

Output: printed to stdout AND saved as analysis.md in the directory of the first delta file.
"""

import sys, os, re, math


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

def parse_delta(path):
    """Return (counters_dict, ordered_counter_list).

    counters_dict: { counter_name: { 'cxi0': int, ..., 'total': int } }
    """
    counters = {}
    order = []
    current = None
    with open(path) as f:
        for line in f:
            line = line.rstrip()
            m = re.match(r'^([a-zA-Z0-9_]+):$', line)
            if m:
                current = m.group(1)
                counters[current] = {}
                order.append(current)
                continue
            m = re.match(r'^\s+(cxi\d+|total):\s*(-?\d+)', line)
            if m and current:
                counters[current][m.group(1)] = int(m.group(2))
    return counters, order


def get_total(c, name):
    return c.get(name, {}).get('total', 0)


def get_nics(c, name):
    return {k: v for k, v in c.get(name, {}).items() if k != 'total'}


def cv(vals):
    """Coefficient of variation as a percentage."""
    if not vals or sum(vals) == 0:
        return 0.0
    mean = sum(vals) / len(vals)
    if mean == 0:
        return 0.0
    return math.sqrt(sum((v - mean) ** 2 for v in vals) / len(vals)) / mean * 100


# ---------------------------------------------------------------------------
# Per-node analysis
# ---------------------------------------------------------------------------

def analyze_node(path, c):
    hostname = re.sub(r'\.delta$', '', re.sub(r'^telemetry\.', '', os.path.basename(path)))
    L = []
    L.append(f'## Node: {hostname}')
    L.append('')

    # ---- AMO health -------------------------------------------------------
    amo_events = get_total(c, 'ixe_disp_amo_events')
    lpe_amos   = get_total(c, 'ixe_disp_lpe_amos')
    lpe_ok     = get_total(c, 'ixe_disp_lpe_amos_ok')

    L.append('### AMO Health')
    if amo_events == 0:
        L.append('No AMO traffic observed on this node (initiator-side or idle).')
    else:
        L.append('| Counter | Total |')
        L.append('|---|---|')
        L.append(f'| `ixe_disp_amo_events` | {amo_events:,} |')
        L.append(f'| `ixe_disp_lpe_amos`   | {lpe_amos:,} |')
        L.append(f'| `ixe_disp_lpe_amos_ok`| {lpe_ok:,} |')
        L.append('')
        if amo_events == lpe_amos == lpe_ok:
            L.append('AMOs are **fully NIC-offloaded** with a **100% success rate**. ✓')
        else:
            if lpe_amos < amo_events:
                pct = lpe_amos / amo_events * 100
                L.append(f'**WARNING**: {amo_events - lpe_amos:,} AMO(s) not forwarded to LPE '
                          f'({pct:.1f}% NIC-offload rate).')
            if lpe_ok < lpe_amos:
                pct = lpe_ok / lpe_amos * 100
                L.append(f'**WARNING**: {lpe_amos - lpe_ok:,} AMO(s) failed '
                          f'({pct:.1f}% success rate).')

    # ---- NIC imbalance ----------------------------------------------------
    L.append('')
    L.append('### NIC Imbalance (AMO events)')
    nic_amos = get_nics(c, 'ixe_disp_amo_events')
    if not nic_amos or amo_events == 0:
        L.append('No AMO traffic to assess balance.')
    else:
        vals = [nic_amos[n] for n in sorted(nic_amos)]
        mean_v  = sum(vals) / len(vals)
        max_v   = max(vals)
        min_v   = min(vals)
        cv_v    = cv(vals)
        L.append('| NIC | AMOs | % of total |')
        L.append('|---|---|---|')
        for n in sorted(nic_amos):
            v = nic_amos[n]
            L.append(f'| {n} | {v:,} | {v/amo_events*100:.1f}% |')
        L.append('')
        L.append(f'Mean/NIC: {mean_v:.0f} &nbsp; '
                  f'Max/Min ratio: {max_v/max(min_v, 1):.1f}× &nbsp; '
                  f'CV: {cv_v:.1f}%')
        L.append('')
        if cv_v > 50 or (min_v > 0 and max_v / min_v > 3):
            L.append('**WARNING**: High NIC imbalance — check process-to-NIC affinity. '
                      'Consider `SHMEM_OFI_DEVICE_ROUND_ROBIN=1` or equivalent CPU pinning.')
        elif cv_v < 20:
            L.append('NIC load is well-balanced. ✓')
        else:
            L.append('Moderate NIC imbalance — consider reviewing CPU-NIC affinity.')

    # ---- ATU cache --------------------------------------------------------
    L.append('')
    L.append('### ATU Cache')
    hits   = get_total(c, 'atu_cache_hit_base_page_size_0')
    misses = get_total(c, 'atu_cache_miss_0')
    total_atu = hits + misses
    hit_rate = hits / total_atu * 100 if total_atu else 0
    L.append('| Metric | Value |')
    L.append('|---|---|')
    L.append(f'| Hits   | {hits:,} |')
    L.append(f'| Misses | {misses:,} |')
    L.append(f'| **Hit rate** | **{hit_rate:.1f}%** |')
    L.append('')
    if hit_rate >= 90:
        L.append('ATU hit rate is excellent. ✓')
    elif hit_rate >= 75:
        L.append('ATU hit rate is acceptable. '
                  'Consider tuning `FI_MR_CACHE_MAX_COUNT`/`FI_MR_CACHE_MAX_SIZE` if throughput is a concern.')
    else:
        L.append('**WARNING**: Low ATU hit rate — likely MR cache thrashing. '
                  'Tune `FI_MR_CACHE_MAX_COUNT` and `FI_MR_CACHE_MAX_SIZE`.')

    # ---- TX / RX ----------------------------------------------------------
    L.append('')
    L.append('### TX / RX Throughput')
    tx = get_total(c, 'hni_sts_tx_ok_octets')
    rx = get_total(c, 'hni_sts_rx_ok_octets')
    L.append('| Direction | Bytes | MB |')
    L.append('|---|---|---|')
    L.append(f'| TX | {tx:,} | {tx/1e6:.2f} |')
    L.append(f'| RX | {rx:,} | {rx/1e6:.2f} |')
    L.append('')
    if tx > rx * 1.05:
        L.append('TX > RX: node acts primarily as **initiator** (sends requests, receives completions).')
    elif rx > tx * 1.05:
        L.append('RX > TX: node acts primarily as **target** (receives requests, sends replies).')
    else:
        L.append('TX ≈ RX: node plays balanced initiator and target roles.')

    # ---- TX packet size histogram -----------------------------------------
    tx_buckets = [
        ('64 B',        'hni_tx_ok_64'),
        ('65–127 B',    'hni_tx_ok_65_to_127'),
        ('128–255 B',   'hni_tx_ok_128_to_255'),
        ('256–511 B',   'hni_tx_ok_256_to_511'),
        ('512–1023 B',  'hni_tx_ok_512_to_1023'),
        ('1024–2047 B', 'hni_tx_ok_1024_to_2047'),
        ('4096–8191 B', 'hni_tx_ok_4096_to_8191'),
        ('>8192 B',     'hni_tx_ok_8192_to_max'),
    ]
    tx_total_pkts = sum(get_total(c, k) for _, k in tx_buckets)
    L.append('')
    L.append('### TX Packet Size Histogram')
    if tx_total_pkts > 0:
        L.append('| Size | Packets | % |')
        L.append('|---|---|---|')
        for label, key in tx_buckets:
            n = get_total(c, key)
            if n > 0:
                L.append(f'| {label} | {n:,} | {n/tx_total_pkts*100:.1f}% |')
    else:
        L.append('No TX packets recorded.')

    # ---- Fabric health ----------------------------------------------------
    L.append('')
    L.append('### Fabric Health')
    error_counters = [
        'hni_llr_tx_replay_event', 'hni_llr_rx_replay_event',
        'hni_llr_tx_nack_ctl_os',  'hni_llr_rx_nack_ctl_os',
        'hni_llr_tx_discard',
        'pct_rsp_err_rcvd', 'pct_rsp_dropped_timeout', 'pct_rsp_dropped_try',
        'pct_bad_seq_nacks', 'pct_no_trs_nacks',
        'ixe_rx_pkt_drop_pct', 'ixe_rx_pkt_drop_ixe_parser',
        'pct_retry_trs_put', 'mst_stalled_waiting_put_crdts',
    ]
    errors = [(k, get_total(c, k)) for k in error_counters if get_total(c, k) != 0]
    if not errors:
        L.append('All error, retry, and drop counters are zero. Fabric is clean. ✓')
    else:
        L.append('**WARNING**: Non-zero error counters:')
        L.append('')
        L.append('| Counter | Value |')
        L.append('|---|---|')
        for k, v in errors:
            L.append(f'| `{k}` | {v:,} |')

    # ---- Latency histogram ------------------------------------------------
    lat_keys = sorted(
        [k for k in c if k.startswith('pct_req_rsp_latency_')],
        key=lambda x: int(x.split('_')[-1])
    )
    if lat_keys:
        L.append('')
        L.append('### Request-Response Latency Distribution')
        lat_data = [(int(k.split('_')[-1]), get_total(c, k)) for k in lat_keys]
        lat_total = sum(v for _, v in lat_data)
        if lat_total > 0:
            wmean = sum(i * v for i, v in lat_data) / lat_total
            L.append(f'Total requests tracked: {lat_total:,} | Weighted mean bucket: {wmean:.2f}')
            L.append('')
            L.append('Buckets with ≥1% share:')
            L.append('')
            L.append('| Bucket | Count | % |')
            L.append('|---|---|---|')
            for i, v in lat_data:
                if v / lat_total >= 0.01:
                    L.append(f'| {i} | {v:,} | {v/lat_total*100:.1f}% |')

    L.append('')
    return '\n'.join(L)


# ---------------------------------------------------------------------------
# Cross-node summary
# ---------------------------------------------------------------------------

def cross_node_summary(all_nodes):
    """all_nodes: list of (path, counters_dict)"""
    L = []
    L.append('## Cross-Node Summary')
    L.append('')
    L.append('### Initiator / Target Roles')
    L.append('')
    L.append('| Node | AMOs received | TX MB | RX MB | Role |')
    L.append('|---|---|---|---|---|')
    for path, c in all_nodes:
        hostname = re.sub(r'\.delta$', '', re.sub(r'^telemetry\.', '', os.path.basename(path)))
        amo = get_total(c, 'ixe_disp_amo_events')
        tx  = get_total(c, 'hni_sts_tx_ok_octets') / 1e6
        rx  = get_total(c, 'hni_sts_rx_ok_octets') / 1e6
        role = ('Initiator' if tx > rx * 1.05
                else 'Target' if rx > tx * 1.05
                else 'Mixed')
        L.append(f'| {hostname} | {amo:,} | {tx:.2f} | {rx:.2f} | {role} |')
    L.append('')

    # Total AMOs across all nodes
    total_amo = sum(get_total(c, 'ixe_disp_amo_events') for _, c in all_nodes)
    total_ok  = sum(get_total(c, 'ixe_disp_lpe_amos_ok')  for _, c in all_nodes)
    L.append(f'Total AMOs dispatched (all nodes): **{total_amo:,}** '
              f'| Successful: **{total_ok:,}**')
    L.append('')
    L.append('### Fabric Health (all nodes)')
    L.append('')
    any_error = False
    error_counters = [
        'hni_llr_tx_replay_event', 'hni_llr_rx_replay_event',
        'hni_llr_tx_nack_ctl_os',  'hni_llr_rx_nack_ctl_os',
        'hni_llr_tx_discard',
        'pct_rsp_err_rcvd', 'pct_rsp_dropped_timeout', 'pct_rsp_dropped_try',
        'pct_bad_seq_nacks', 'pct_no_trs_nacks',
        'ixe_rx_pkt_drop_pct', 'ixe_rx_pkt_drop_ixe_parser',
    ]
    for k in error_counters:
        total_v = sum(get_total(c, k) for _, c in all_nodes)
        if total_v:
            if not any_error:
                L.append('| Counter | Total across nodes |')
                L.append('|---|---|')
                any_error = True
            L.append(f'| `{k}` | {total_v:,} |')
    if not any_error:
        L.append('No fabric errors across any node. ✓')
    L.append('')
    return '\n'.join(L)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    args = sys.argv[1:]
    if not args:
        print(f'Usage: {sys.argv[0]} <file.delta|directory> ...', file=sys.stderr)
        sys.exit(1)

    delta_files = []
    for a in args:
        if os.path.isdir(a):
            found = sorted(
                os.path.join(a, f) for f in os.listdir(a) if f.endswith('.delta')
            )
            delta_files.extend(found)
        elif os.path.isfile(a):
            delta_files.append(a)
        else:
            print(f'WARNING: not found: {a}', file=sys.stderr)

    if not delta_files:
        print('No delta files found.', file=sys.stderr)
        sys.exit(1)

    out_dir  = os.path.dirname(os.path.abspath(delta_files[0]))
    out_path = os.path.join(out_dir, 'analysis.md')
    workload = os.path.basename(out_dir)

    sections = []
    sections.append('# CXI Telemetry Delta Analysis')
    sections.append('')
    sections.append(f'**Workload**: `{workload}`  ')
    sections.append(f'**Nodes analysed**: {len(delta_files)}  ')
    sections.append('')

    all_nodes = []
    for path in sorted(delta_files):
        c, order = parse_delta(path)
        all_nodes.append((path, c))
        sections.append(analyze_node(path, c))

    if len(all_nodes) > 1:
        sections.append(cross_node_summary(all_nodes))

    md = '\n'.join(sections)
    print(md)
    with open(out_path, 'w') as f:
        f.write(md)
    print(f'\nAnalysis written to: {out_path}', file=sys.stderr)


if __name__ == '__main__':
    main()
