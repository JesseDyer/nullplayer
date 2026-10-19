#!/bin/bash
#
# S3 motion sweep of the Winamp Modern (`.wal`) corpus (corpus-runner-plan.md §3 S3, §7 step 4).
# Does what a skin declares as moving actually move, at rest?
#
#   scripts/wal_motion_sweep.sh <outdir> [--corpus <dir[:dir…]>] [--shards K] [--allow-dirty]
#
# Output: <outdir>/motion.tsv, one row per (skin, container, opening layout), and a summary on
# stdout. Columns and their reading are in
# skills/winamp-modern-skin-guide/reference/harness.md § "The motion sweep".
#
# Every skin costs ~4 s of wall time (the ladder ends at t = 4 s), so pass --shards = cores.
# A run is a build, like wal_render_sweep.sh: it refuses a dirty tree without --allow-dirty, and
# fails if any archive is missing its rows.

set -u -o pipefail

source "$(dirname "$0")/lib/swiftpm.sh"
source "$(dirname "$0")/lib/wal_corpus.sh"

usage() {
    echo "usage: wal_motion_sweep.sh <outdir> [--corpus <dir[:dir…]>] [--shards K] [--allow-dirty]" >&2
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
[[ "$shards" =~ ^[1-9][0-9]*$ ]] || { echo "wal_motion_sweep: --shards takes a positive count" >&2; usage; }

list=$(wal_corpus_archives "$corpus") || exit 1
archives=$(printf '%s' "$list" | grep -c .)
[ "$archives" -gt 0 ] || { echo "wal_motion_sweep: no .wal archives in $corpus" >&2; exit 1; }

if [ "$allow_dirty" -eq 0 ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    echo "wal_motion_sweep: working tree is dirty; commit, use a worktree, or pass --allow-dirty" >&2
    git status --short >&2
    exit 1
fi

mkdir -p "$out"
out=$(cd "$out" && pwd)
rm -f "$out"/motion-*.tsv "$out"/raw-*.txt
[ "$shards" -gt "$archives" ] && shards=$archives
echo "wal_motion_sweep: $archives archives in $shards shard(s) -> $out (rev $(git rev-parse --short HEAD 2>/dev/null || echo unknown))"
if ! swift build --build-tests ${SWIFTPM_ARGS[@]+"${SWIFTPM_ARGS[@]}"} > "$out/build.txt" 2>&1; then
    echo "wal_motion_sweep: build failed; see $out/build.txt" >&2
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
    WINAMP_MODERN_MOTION_SWEEP="$wal" \
    WINAMP_MODERN_MOTION_SWEEP_OUT="$out/motion-$shard.tsv" \
        xcrun xctest -XCTest NullPlayerAppTests.WinampModernMotionSweepTests "$bundle" \
        > "$out/raw-$shard.txt" 2>&1 &
    pids+=($!)
done
status=0
for pid in "${pids[@]}"; do wait "$pid" || status=$?; done
[ "$status" -eq 0 ] || echo "wal_motion_sweep: a shard exited $status; read $out/raw-*.txt before trusting the result" >&2

python3 -I - "$out" "$list" <<'PYMOTION'
import glob, os, sys

out, archives = sys.argv[1], {os.path.basename(p) for p in sys.argv[2].splitlines() if p}
COLUMNS = ["skin", "container", "layout", "open", "frames", "verdict", "animatedlayers", "autoplay",
           "timer", "suspect", "moved", "anim"]
rows = []
for path in sorted(glob.glob(os.path.join(out, "motion-*.tsv"))):
    rows += [line.rstrip("\n").split("\t") for line in open(path, errors="replace") if line.strip()]
missing = sorted(archives - {row[0] for row in rows}, key=str.lower)
if missing:
    sys.exit(f"wal_motion_sweep: {len(missing)} archives have no rows (a shard crashed?): " + ", ".join(missing[:10]))
rows.sort(key=lambda row: (row[0].lower(), row[0], row[1].lower(), row[2]))
with open(os.path.join(out, "motion.tsv"), "w") as handle:
    handle.write("\t".join(COLUMNS) + "\n")
    handle.writelines("\t".join(row) + "\n" for row in rows)

by_skin = {}
for row in rows:
    by_skin.setdefault(row[0], []).append(dict(zip(COLUMNS, row)))
failed = [s for s, r in by_skin.items() if r[0]["verdict"] == "failed"]
counts = {}
for row in rows:
    counts[row[5]] = counts.get(row[5], 0) + 1
# Skin-level suspect: it declares a self-playing (autoplay) animatedlayer and no layout of any window
# moved at all. The plan's rule also counted a script Timer, but 2026-10-19's first run found one in
# nearly every skin, mostly for interaction, so Timer alone named half the corpus.
still = sorted((s for s, r in by_skin.items() if s not in failed
                and all(x["verdict"] == "static" for x in r)
                and any(x["autoplay"] != "0" for x in r)), key=str.lower)
layouts = [r for r in rows if r[9] == "1"]
causes = {}
for row in rows:
    for item in row[11].split(","):
        if "=" in item:
            cause = item.rsplit("=", 1)[1]
            causes[cause] = causes.get(cause, 0) + 1
print(f"wal_motion_sweep: {len(rows)} layouts over {len(by_skin)} skins -> {out}/motion.tsv; "
      + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
print("  animatedlayers: " + (", ".join(f"{k} {v}" for k, v in sorted(causes.items())) or "none"))
print(f"  suspect layouts (animatedlayer declared, static): {len(layouts)}")
print(f"  suspect skins (autoplay declared, nothing moved): {len(still)}")
for skin in still:
    print("    " + skin)
PYMOTION
