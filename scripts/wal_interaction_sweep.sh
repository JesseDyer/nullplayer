#!/bin/bash
#
# S3 interaction sweep of the Winamp Modern (`.wal`) corpus (corpus-runner-plan.md §3 S3, §7 step 5).
# Every object a script hooks the mouse on, driven with the gesture its bindings call for: does
# anything happen?
#
#   scripts/wal_interaction_sweep.sh <outdir> [--corpus <dir[:dir…]>] [--shards K] [--allow-dirty]
#
# Output: <outdir>/interaction.tsv, one row per (skin, container, layout, object, gesture), and the
# dead-control summary on stdout. Columns and their reading are in
# skills/winamp-modern-skin-guide/reference/harness.md § "The interaction sweep".
#
# Every gesture is a fresh skin load plus ~2.5 s of settling, mostly asleep, so pass --shards at
# about three times the core count (30 on 10 cores; measured at ~335% CPU with 10).
# A run is a build, like wal_render_sweep.sh: it refuses a dirty tree without --allow-dirty, and
# fails if any archive is missing its rows.

set -u -o pipefail

source "$(dirname "$0")/lib/swiftpm.sh"
source "$(dirname "$0")/lib/wal_corpus.sh"

usage() {
    echo "usage: wal_interaction_sweep.sh <outdir> [--corpus <dir[:dir…]>] [--shards K] [--allow-dirty]" >&2
    exit 2
}

out="" corpus="$WAL_CORPUS_DEFAULT" allow_dirty=0 shards=1
while [ $# -gt 0 ]; do
    case "$1" in
        --allow-dirty) allow_dirty=1; shift ;;
        --corpus) corpus="${2:-}"; shift 2 ;;
        --shards) shards="${2:-}"; shift 2 ;;
        -*) echo "unknown option: $1" >&2; usage ;;
        *) [ -n "$out" ] && usage; out="$1"; shift ;;
    esac
done
[ -n "$out" ] || usage
[[ "$shards" =~ ^[1-9][0-9]*$ ]] || { echo "wal_interaction_sweep: --shards takes a positive count" >&2; usage; }

list=$(wal_corpus_archives "$corpus") || exit 1
archives=$(printf '%s' "$list" | grep -c .)
[ "$archives" -gt 0 ] || { echo "wal_interaction_sweep: no .wal archives in $corpus" >&2; exit 1; }

if [ "$allow_dirty" -eq 0 ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    echo "wal_interaction_sweep: working tree is dirty; commit, use a worktree, or pass --allow-dirty" >&2
    git status --short >&2
    exit 1
fi

mkdir -p "$out"
out=$(cd "$out" && pwd)
rm -f "$out"/interaction-*.tsv "$out"/raw-*.txt
[ "$shards" -gt "$archives" ] && shards=$archives
echo "wal_interaction_sweep: $archives archives in $shards shard(s) -> $out (rev $(git rev-parse --short HEAD 2>/dev/null || echo unknown))"
if ! swift build --build-tests ${SWIFTPM_ARGS[@]+"${SWIFTPM_ARGS[@]}"} > "$out/build.txt" 2>&1; then
    echo "wal_interaction_sweep: build failed; see $out/build.txt" >&2
    tail -30 "$out/build.txt" >&2
    exit 1
fi

# Sharded as wal_render_sweep.sh does (B170): every K-th archive of the sha256 order, run on the
# built bundle with `xctest` because SwiftPM's .build lock serialises K `swift test`s.
bundle="$(swiftpm_bin_path debug 2>/dev/null)/NullPlayerPackageTests.xctest"
ordered=$(printf '%s\n' "$list" | while IFS= read -r path; do
              printf '%s\t%s\n' "$(shasum -a 256 "$path" | cut -d' ' -f1)" "$path"
          done | sort)
pids=()
for ((shard = 0; shard < shards; shard++)); do
    wal=$(printf '%s\n' "$ordered" | awk -F'\t' -v k="$shards" -v i="$shard" '(NR - 1) % k == i { printf "%s:", $2 }')
    # Redirect, do not pipe.
    WINAMP_MODERN_INTERACTION_SWEEP="$wal" \
    WINAMP_MODERN_INTERACTION_SWEEP_OUT="$out/interaction-$shard.tsv" \
        xcrun xctest -XCTest NullPlayerAppTests.WinampModernInteractionSweepTests "$bundle" \
        > "$out/raw-$shard.txt" 2>&1 &
    pids+=($!)
done
status=0
for pid in "${pids[@]}"; do wait "$pid" || status=$?; done
[ "$status" -eq 0 ] || echo "wal_interaction_sweep: a shard exited $status; read $out/raw-*.txt before trusting the result" >&2

python3 -I - "$out" "$list" <<'PYINTERACTION'
import glob, os, sys
from collections import Counter

out, archives = sys.argv[1], {os.path.basename(p) for p in sys.argv[2].splitlines() if p}
COLUMNS = ["skin", "container", "layout", "object", "gesture", "point", "hit", "verdict", "handlers",
           "failed", "changed", "effect"]
rows = []
for path in sorted(glob.glob(os.path.join(out, "interaction-*.tsv"))):
    rows += [line.rstrip("\n").split("\t") for line in open(path, errors="replace") if line.strip()]
missing = sorted(archives - {row[0] for row in rows}, key=str.lower)
if missing:
    sys.exit(f"wal_interaction_sweep: {len(missing)} archives have no rows (a shard crashed?): " + ", ".join(missing[:10]))
rows.sort(key=lambda row: (row[0].lower(), row[0], row[1].lower(), row[2], row[3], row[4]))
with open(os.path.join(out, "interaction.tsv"), "w") as handle:
    handle.write("\t".join(COLUMNS) + "\n")
    handle.writelines("\t".join(row) + "\n" for row in rows)

driven = [r for r in rows if r[7] not in ("failed", "none")]
skins = {r[0] for r in rows}
print(f"wal_interaction_sweep: {len(driven)} gestures over {len(skins)} skins -> {out}/interaction.tsv; "
      + ", ".join(f"{k} {v}" for k, v in sorted(Counter(r[7] for r in rows).items())))
codes = Counter(code for r in driven if r[9] != "-" for code in r[9].split(","))
print("  blocked by: " + (", ".join(f"{k} {v}" for k, v in codes.most_common()) or "nothing"))
# The dead-control list: per skin, the gestures that did nothing observable or failed.
dead = Counter(r[0] for r in driven if r[7] in ("blocked", "silent", "unbound", "unreachable"))
total = Counter(r[0] for r in driven)
print("  most dead (dead/driven):")
for skin, count in sorted(dead.items(), key=lambda kv: (-kv[1], kv[0].lower()))[:15]:
    print(f"    {count}/{total[skin]}  {skin}")
PYINTERACTION
