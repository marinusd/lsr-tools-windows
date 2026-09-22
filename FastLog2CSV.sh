#!/usr/bin/env bash
# fastlog2csv.sh — convert F.A.S.T. Classic (C-Com WP) binary datalogs to CSV.
#
# Usage:  ./fastlog2csv.sh [-o OUTDIR] file1.log [file2.log ...]
#         Writes <name>.csv next to each input (or into OUTDIR).
#
# Format (reverse-engineered):
#   0x000        ASCII version ("22"), u16 channel count N, N u16 channel ids
#   0x204        N channel definitions, 58 bytes each:
#                  name[16] units[8] u16 u16 u16 f32_scale f32_offset
#                  u16 raw_min u16 raw_max f32 disp_max f32 disp_min fmt[8]
#   defs+22      data records: N x u16 raw values + u32 timestamp (ms)
#   Engineering value = raw * scale + offset. Channels whose header scale
#   is 1.0 (temps, MAP) are stored as raw sensor counts; they are emitted
#   as-is, matching what C-Com WP logs internally.
#
# Requires: bash, python3 (used for binary struct decoding).

set -euo pipefail

outdir=""
while getopts "o:h" opt; do
  case $opt in
    o) outdir=$OPTARG ;;
    h|*) grep '^#' "$0" | head -12; exit 0 ;;
  esac
done
shift $((OPTIND-1))
[ $# -ge 1 ] || { echo "usage: $0 [-o OUTDIR] file.log ..." >&2; exit 1; }
[ -n "$outdir" ] && mkdir -p "$outdir"

for f in "$@"; do
  [ -r "$f" ] || { echo "skip: cannot read $f" >&2; continue; }
  base=$(basename "${f%.*}").csv
  out=${outdir:+$outdir/}${outdir:-$(dirname "$f")/}
  out=${outdir:+$outdir/$base}
  [ -n "$outdir" ] || out=$(dirname "$f")/$base

  python3 - "$f" "$out" <<'PYEOF'
import struct, sys, csv

src, dst = sys.argv[1], sys.argv[2]
d = open(src, 'rb').read()

if len(d) < 0x210:
    sys.exit(f"error: {src}: file too small to be a FAST log")

nchan, = struct.unpack_from('<H', d, 2)
if not 1 <= nchan <= 32:
    sys.exit(f"error: {src}: implausible channel count {nchan}; not a FAST Classic log?")

DEF0, DEFSZ = 0x204, 58
chans = []
for i in range(nchan):
    o = DEF0 + DEFSZ * i
    name  = d[o:o+16].split(b'\0')[0].decode('ascii', 'replace').strip()
    units = d[o+16:o+24].split(b'\0')[0].decode('ascii', 'replace').strip()
    scale, offset = struct.unpack_from('<ff', d, o+30)
    col = name if not units or units in name else f"{name} [{units}]"
    if name.upper().startswith('MAP') and scale == 1.0:
        scale = 14.7 / 245        # raw counts -> psia, calibrated from engine-off atmospheric reading
    chans.append((col, scale, offset))

data0 = DEF0 + DEFSZ * nchan + 22
recsz = 2 * nchan + 4
nrec = (len(d) - data0) // recsz

rows, prev_ts = [], -1
o = data0
for _ in range(nrec):
    raw = struct.unpack_from(f'<{nchan}H', d, o)
    ts, = struct.unpack_from('<I', d, o + 2 * nchan)
    if ts < prev_ts:
        break                       # non-monotonic time: ran past end of data
    prev_ts = ts
    rows.append([ts / 1000.0] + [round(r * s + off, 4) for r, (_, s, off) in zip(raw, chans)])
    o += recsz

if not rows:
    sys.exit(f"error: {src}: no valid data records found")

with open(dst, 'w', newline='') as fh:
    w = csv.writer(fh)
    w.writerow(['Time_s'] + [c for c, _, _ in chans])
    w.writerows(rows)

dur = rows[-1][0] - rows[0][0]
print(f"{src}: {len(rows)} records, {nchan} channels, {dur:.1f}s -> {dst}")
PYEOF
done
