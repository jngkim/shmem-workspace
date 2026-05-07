#!/bin/bash
#
# CXI NIC telemetry snapshot — auto-detects NIC count and sums each counter across all instances.
# Call once before and once after a workload; diff the two output files to see deltas.
#
# Counter guide:
#
# ATU (Address Translation Unit) — affects all RMA/AMO operations:
#   atu_cache_hit_base_page_size_0  : ATU TLB hits (fast path). High hit rate = good MR reuse.
#   atu_cache_miss_0                : ATU TLB misses (triggers page walk). High = MR thrashing.
#   Use case: diagnose FI_MR_CACHE_MAX_COUNT / FI_MR_CACHE_MAX_SIZE tuning.
#
# AMO dispatch (target-side, inbound atomics):
#   ixe_disp_amo_events    : Total AMOs received and dispatched by IXE engine.
#   ixe_disp_lpe_amos      : AMOs forwarded to LPE for processing.
#   ixe_disp_lpe_amos_ok   : AMOs completed successfully. Should equal ixe_disp_lpe_amos.
#   Use case: confirm shmem_atomic_fetch_add / shmem_atomic_add are hitting the NIC;
#             compare SOS vs CraySHMEMX AMO event counts for the same workload.
#
# Put flow control:
#   pct_retry_trs_put           : Put retries due to TRS exhaustion. Nonzero = resource pressure.
#   mst_stalled_waiting_put_crdts : Cycles stalled waiting for put credits. High = backpressure.
#   Use case: diagnose put throughput degradation under high message rate.
#
# TX/RX throughput (octets):
#   hni_sts_tx_ok_octets : Total bytes successfully transmitted.
#   hni_sts_rx_ok_octets : Total bytes successfully received.
#   Use case: confirm data is flowing; sanity-check against expected message volume.
#
# TX packet size histogram (sent packets by size bucket):
#   hni_tx_ok_64          : 64-byte packets (typical for small AMOs/control)
#   hni_tx_ok_65_to_127   : 65-127 byte packets
#   hni_tx_ok_128_to_255  : 128-255 byte packets (inject threshold range)
#   hni_tx_ok_256_to_511  : 256-511 byte packets
#   hni_tx_ok_512_to_1023 : 512-1023 byte packets
#   hni_tx_ok_1024_to_2047: 1024-2047 byte packets
#   hni_tx_ok_4096_to_8191: 4096-8191 byte packets (NAIL put range)
#   hni_tx_ok_8192_to_max : >8192 byte packets
#   Use case: verify inject path is being used (more small packets after inject_size fix);
#             characterize message size distribution of a workload.
#
# RX packet size histogram (received packets by size bucket):
#   hni_rx_ok_64          : 64-byte packets
#   hni_rx_ok_65_to_127   : 65-127 byte packets
#   hni_rx_ok_128_to_255  : 128-255 byte packets
#   hni_rx_ok_256_to_511  : 256-511 byte packets
#   hni_rx_ok_512_to_1023 : 512-1023 byte packets
#   hni_rx_ok_1024_to_2047: 1024-2047 byte packets
#   hni_rx_ok_4096_to_8191: 4096-8191 byte packets
#   hni_rx_ok_8192_to_max : >8192 byte packets
#   Use case: confirm RX side matches TX side; asymmetry may indicate drops.
#
# Link-layer reliability (LLR replay/nack):
#   hni_llr_tx_replay_event : TX frames replayed due to link errors.
#   hni_llr_rx_replay_event : RX frames received as replays.
#   hni_llr_tx_nack_ctl_os  : NACKs sent by local NIC (rejected remote frames).
#   hni_llr_rx_nack_ctl_os  : NACKs received from remote NIC.
#   hni_llr_tx_discard      : TX frames discarded (unrecoverable link error).
#   Use case: detect fabric link errors causing retransmits; nonzero = investigate cabling/optics.
#
# PCT protocol errors and drops (request/response layer):
#   pct_rsp_err_rcvd        : Error responses received (remote side rejected request).
#   pct_rsp_dropped_timeout : Responses dropped due to timeout (remote unresponsive).
#   pct_rsp_dropped_try     : Responses dropped because retries exhausted.
#   pct_bad_seq_nacks       : NACKs due to bad sequence numbers (ordering issue).
#   pct_no_trs_nacks        : NACKs due to no TRS available (resource exhaustion).
#   Use case: diagnose put/get correctness failures; nonzero = potential data loss.
#
# IXE inbound packet drops:
#   ixe_rx_pkt_drop_pct        : Packets dropped by PCT (protocol engine overloaded).
#   ixe_rx_pkt_drop_ixe_parser : Packets dropped by IXE parser (malformed or overrun).
#   Use case: detect inbound packet loss; nonzero indicates NIC is overwhelmed or sees bad packets.
#
# Latency histogram (request/response round-trip, logarithmic buckets):
#   pct_req_rsp_latency_0..31 : Histogram of fabric RTT. Lower buckets = faster.
#                               Bucket boundaries are not published; treat as relative comparison.
#   Use case: compare latency distribution between SOS and CraySHMEMX runs;
#             identify tail latency or bimodal distributions indicating contention.

NUM_NICS=$(ls -d /sys/class/cxi/cxi* 2>/dev/null | wc -l)
OUTDIR="${TELEMETRY_OUTDIR:-$(pwd)}"
#exec > "${OUTDIR}/telemetry.$(hostname).log" 2>&1
exec > "${OUTDIR}/telemetry.$(hostname).${POSTFIX}" 2>&1
echo "=== $(hostname) === (${NUM_NICS} NICs)"
for c in \
    atu_cache_hit_base_page_size_0 \
    atu_cache_miss_0 \
    ixe_disp_amo_events \
    ixe_disp_lpe_amos \
    ixe_disp_lpe_amos_ok \
    pct_retry_trs_put \
    mst_stalled_waiting_put_crdts \
    hni_sts_tx_ok_octets \
    hni_sts_rx_ok_octets \
    hni_tx_ok_64 \
    hni_tx_ok_65_to_127 \
    hni_tx_ok_128_to_255 \
    hni_tx_ok_256_to_511 \
    hni_tx_ok_512_to_1023 \
    hni_tx_ok_1024_to_2047 \
    hni_tx_ok_4096_to_8191 \
    hni_tx_ok_8192_to_max \
    hni_rx_ok_64 \
    hni_rx_ok_65_to_127 \
    hni_rx_ok_128_to_255 \
    hni_rx_ok_256_to_511 \
    hni_rx_ok_512_to_1023 \
    hni_rx_ok_1024_to_2047 \
    hni_rx_ok_4096_to_8191 \
    hni_rx_ok_8192_to_max \
    hni_llr_tx_replay_event \
    hni_llr_rx_replay_event \
    hni_llr_tx_nack_ctl_os \
    hni_llr_rx_nack_ctl_os \
    hni_llr_tx_discard \
    pct_rsp_err_rcvd \
    pct_rsp_dropped_timeout \
    pct_rsp_dropped_try \
    pct_bad_seq_nacks \
    pct_no_trs_nacks \
    ixe_rx_pkt_drop_pct \
    ixe_rx_pkt_drop_ixe_parser \
    $(seq -f 'pct_req_rsp_latency_%g' 0 31); do
    total=0
    echo "$c:"
    for n in /sys/class/cxi/cxi*/device/telemetry/$c; do
        val=$(cat "$n" | cut -d'@' -f1)
        total=$((total + val))
        nic=$(echo "$n" | grep -oP 'cxi\d+' | head -1)
        echo "  $nic: $val"
    done
    echo "  total: $total"
done
