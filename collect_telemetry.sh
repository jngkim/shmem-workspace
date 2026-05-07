#!/bin/bash
out_file=$1.$(hostname)
echo "=== $(hostname) ===" > $out_file
for c in \
    atu_cache_hit_base_page_size_0 \
    atu_cache_miss_0 \
    ixe_disp_amo_events \
    ixe_disp_lpe_amos \
    ixe_disp_lpe_amos_ok \
    pct_retry_trs_put \
    mst_stalled_waiting_put_crdts \
    $(seq -f 'pct_req_rsp_latency_%g' 0 31); do
    total=0
    for n in /sys/class/cxi/cxi*/device/telemetry/$c; do
      val=$(cat $n | cut -d'@' -f1)
      total=$((total + val))
    done
    echo "$c: $total" >> $out_file
done
echo "------------------------------" >> ${output}
