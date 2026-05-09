#!/usr/bin/env python3
"""
Plot OSU Put Message Rate vs message size for each SHMEM_BOUNCE_SIZE.

Accepts a directory containing sos.put_mr.*.dat files (one per proc-count
variant) or a single .dat file.  When a matching shmemx.put_mr.*.dat file
is found alongside a sos file, its data is appended as a SHMEMX entry.

Usage (directory — all proc-count variants):
    conda run -n aprendo python3 analyze_osu_cray_env.py aurora/osu.bbsz.8464675

Usage (directory — restrict to one proc count):
    conda run -n aprendo python3 analyze_osu_cray_env.py aurora/osu.bbsz.8464675 --procs p64

Usage (single file):
    conda run -n aprendo python3 analyze_osu_cray_env.py aurora/osu.bbsz.8464675/sos.put_mr.N8.p64.dat
"""

import argparse
import re
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


# ── Parsing ───────────────────────────────────────────────────────────────────

# Matches "SHMEM_BOUNCE_SIZE: 512" or "Bounce buffer size: Default"
_BBSZ_RE   = re.compile(r"SHMEM_BOUNCE_SIZE:\s*(\d+)", re.IGNORECASE)
_DEFAULT_RE = re.compile(r"Bounce buffer size:\s*Default", re.IGNORECASE)
_DATA_RE    = re.compile(r"^\s*(\d+)\s+([\d.]+)\s*$")


def parse_file(path):
    """
    Return a dict: bbsz_label (str) -> {size (int): msg_rate (float)}.
    bbsz_label is "Default" or the numeric value as a string.
    Order of sections is preserved via insertion-order dict.
    """
    sections = {}   # label -> {size: rate}
    current_label = None
    current_data  = {}
    in_data       = False

    with open(path) as fh:
        for line in fh:
            # Check for a new section header
            m_default = _DEFAULT_RE.search(line)
            m_bbsz    = _BBSZ_RE.search(line)

            if m_default or m_bbsz:
                # Save previous section
                if current_label is not None and current_data:
                    sections[current_label] = current_data
                current_label = "Default" if m_default else m_bbsz.group(1)
                current_data  = {}
                in_data       = False
                continue

            # Detect start of data table
            if "Size" in line and "Messages/s" in line:
                in_data = True
                continue

            if in_data:
                m = _DATA_RE.match(line)
                if m:
                    size = int(m.group(1))
                    rate = float(m.group(2))
                    current_data[size] = rate

    # Save the last section
    if current_label is not None and current_data:
        sections[current_label] = current_data

    return sections


def parse_shmemx_file(path):
    """Parse a plain two-column shmemx dat file. Returns {size: rate}."""
    data = {}
    in_data = False
    with open(path) as fh:
        for line in fh:
            if "Size" in line and "Messages/s" in line:
                in_data = True
                continue
            if in_data:
                m = _DATA_RE.match(line)
                if m:
                    data[int(m.group(1))] = float(m.group(2))
    return data


# ── CSV export ───────────────────────────────────────────────────────────────

def save_csv(sections, output):
    """Write message rates to CSV with Size as the first column and one
    column per SHMEM_BOUNCE_SIZE label."""
    import csv

    # Union of all sizes, sorted
    all_sizes = sorted({s for data in sections.values() for s in data})
    labels    = list(sections.keys())

    with open(output, "w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerow(["Size"] + [f"BBSZ={l}" if l != "Default" else "Default" for l in labels])
        for size in all_sizes:
            row = [size] + [sections[l].get(size, "") for l in labels]
            writer.writerow(row)

    print(f"Saved CSV: {output}")


# ── Plotting ──────────────────────────────────────────────────────────────────

# Distinct (marker, linestyle) combinations so lines remain distinguishable
# even in greyscale or when printed.
_STYLES = [
    ("o", "-"),
    ("s", "--"),
    ("^", "-."),
    ("D", ":"),
    ("v", "-"),
    ("P", "--"),
    ("X", "-."),
    ("*", ":"),
    ("h", "-"),
    ("p", "--"),
]


def human_size(n):
    """Return a human-readable byte label (e.g. 4K, 1M)."""
    for unit, threshold in [("M", 1 << 20), ("K", 1 << 10)]:
        if n >= threshold and n % threshold == 0:
            return f"{n // threshold}{unit}"
    return str(n)


def plot(sections, output, title):
    fig, ax = plt.subplots(figsize=(10, 6))

    cmap   = plt.get_cmap("tab10")
    labels = list(sections.keys())

    for idx, label in enumerate(labels):
        data   = sections[label]
        sizes  = sorted(data.keys())
        rates  = [data[s] / 1e6 for s in sizes]   # convert to M msgs/s
        marker, ls = _STYLES[idx % len(_STYLES)]

        legend_label = f"BBSZ={label}" if label != "Default" else "Default (no BBSZ)"
        ax.plot(
            range(len(sizes)), rates,
            marker=marker, linestyle=ls, markersize=4, linewidth=1.5,
            color=cmap(idx % 10),
            label=legend_label,
        )

    # x-axis ticks: use sizes from the first section
    first_sizes = sorted(next(iter(sections.values())).keys())
    ax.set_xticks(range(len(first_sizes)))
    ax.set_xticklabels([human_size(s) for s in first_sizes],
                       rotation=45, ha="right", fontsize=8)

    ax.set_xlabel("Message Size (bytes)")
    ax.set_ylabel("Message Rate (M msgs/s)")
    ax.set_title(title)
    ax.legend(fontsize=8, ncol=2)
    ax.grid(True, linestyle="--", alpha=0.5)

    plt.tight_layout()
    plt.savefig(output, dpi=150)
    print(f"Saved: {output}")


def plot_by_size(sections, sizes, output, title):
    """For each requested message size, plot rate vs BBSZ value.

    x-axis : BBSZ labels (Default, 512, 1024, …) in the order they appear
    y-axis : message rate (M msgs/s)
    one line per message size
    """
    labels = list(sections.keys())          # ordered BBSZ labels
    x      = range(len(labels))
    cmap   = plt.get_cmap("tab10")

    fig, ax = plt.subplots(figsize=(10, 6))

    plotted = 0
    for idx, sz in enumerate(sizes):
        rates  = [sections[lbl].get(sz, float("nan")) / 1e6 for lbl in labels]
        marker, ls = _STYLES[idx % len(_STYLES)]
        ax.plot(
            x, rates,
            marker=marker, linestyle=ls, markersize=5, linewidth=1.8,
            color=cmap(idx % 10),
            label=f"Size={human_size(sz)}",
        )
        plotted += 1

    if plotted == 0:
        print("WARNING: none of the requested sizes found in data", file=sys.stderr)
        plt.close(fig)
        return

    x_labels = [l if l in ("Default", "SHMEMX") else f"{int(l):,}" for l in labels]
    ax.set_xticks(list(x))
    ax.set_xticklabels(x_labels, rotation=45, ha="right", fontsize=8)

    ax.set_xlabel("SHMEM_BOUNCE_SIZE")
    ax.set_ylabel("Message Rate (M msgs/s)")
    ax.set_title(title)
    ax.legend(fontsize=9)
    ax.grid(True, linestyle="--", alpha=0.5)

    plt.tight_layout()
    plt.savefig(output, dpi=150)
    print(f"Saved: {output}")


# ── CLI ───────────────────────────────────────────────────────────────────────

def _process(inpath, outpath, csvpath, title_override, sizes, shmemx_path=None):
    title = title_override or f"OSU Put Message Rate vs SHMEM_BOUNCE_SIZE\n({inpath.name})"
    sections = parse_file(inpath)
    if not sections:
        print(f"ERROR: no data sections found in {inpath}", file=sys.stderr)
        return
    print(f"Found {len(sections)} BBSZ sections: {', '.join(sections.keys())}")
    if shmemx_path is not None and shmemx_path.exists():
        shmemx_data = parse_shmemx_file(shmemx_path)
        if shmemx_data:
            sections["SHMEMX"] = shmemx_data
            print(f"Appended SHMEMX data from {shmemx_path.name}")
    save_csv(sections, csvpath)
    plot(sections, outpath, title)
    size_outpath = outpath.with_stem(outpath.stem + ".by_size")
    size_title   = title.replace("vs SHMEM_BOUNCE_SIZE", "per Size vs SHMEM_BOUNCE_SIZE")
    plot_by_size(sections, sizes, size_outpath, size_title)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("input", help="OSU benchmark output file or directory containing sos.put_mr.*.dat files")
    parser.add_argument("-o", "--output",
                        help="Output PNG path (default: <input>.png, ignored when input is a directory)")
    parser.add_argument("--csv",
                        help="Output CSV path (default: <input>.csv, ignored when input is a directory)")
    parser.add_argument("--title",
                        help="Plot title (default: derived from filename)")
    parser.add_argument(
        "--procs",
        help="Restrict to one proc-count variant, e.g. p64 (directory mode only)",
    )
    parser.add_argument(
        "--sizes", default="1024,2048,4096,8192",
        help="Comma-separated message sizes for the per-size plot (default: 1024,2048,4096,8192)",
    )
    args = parser.parse_args()

    sizes = [int(s) for s in args.sizes.split(",")]

    inpath = Path(args.input)
    if inpath.is_dir():
        pattern = f"sos.put_mr.*.{args.procs}.dat" if args.procs else "sos.put_mr.*.dat"
        dat_files = sorted(inpath.glob(pattern))
        if not dat_files:
            print(f"ERROR: no files matching '{pattern}' found in {inpath}", file=sys.stderr)
            sys.exit(1)
        for dat in dat_files:
            # e.g. sos.put_mr.N8.p64.dat -> shmemx.put_mr.N8.p64.dat
            shmemx = dat.with_name(dat.name.replace("sos.", "shmemx.", 1))
            _process(dat, dat.with_suffix(".png"), dat.with_suffix(".csv"),
                     args.title, sizes, shmemx_path=shmemx)
    else:
        outpath = Path(args.output) if args.output else inpath.with_suffix(".png")
        csvpath = Path(args.csv)    if args.csv    else inpath.with_suffix(".csv")
        _process(inpath, outpath, csvpath, args.title, sizes)


if __name__ == "__main__":
    main()
