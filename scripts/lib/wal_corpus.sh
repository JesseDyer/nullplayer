#!/bin/bash
# The Winamp Modern (`.wal`) test corpus (B167). Source this file; every corpus script defaults to
# WAL_CORPUS_DEFAULT and takes `--corpus` as a `:`-separated list of directories.
#
# The corpus lives outside the app's own skin folder: `WinampModernSkins/` is the importer's install
# folder, so anything there is in the user's skin menu. Tier is recorded in the committed
# docs/winamp-modern/corpus-manifest.tsv; see docs/winamp-modern/corpus-runner-plan.md §8.
WAL_CORPUS_ROOT="$HOME/Library/Application Support/NullPlayer/WinampModernCorpus"
WAL_CORPUS_DEFAULT="$WAL_CORPUS_ROOT/gold:$WAL_CORPUS_ROOT/silver"

# wal_corpus_archives <dir[:dir…]>: every archive, one path per line; fails on a missing directory.
# `*.[wW][aA][lL]`, `-type f`: a plain `*.wal` drops `Defix Hi-END 200.WAL`.
wal_corpus_archives() {
    local dirs dir
    IFS=: read -ra dirs <<<"$1"
    for dir in "${dirs[@]}"; do
        [ -d "$dir" ] || { echo "no corpus directory at $dir" >&2; return 1; }
    done
    find "${dirs[@]}" -maxdepth 1 -type f -name '*.[wW][aA][lL]'
}
