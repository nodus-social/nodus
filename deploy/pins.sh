# Sourced by deploy/build.sh and deploy/check-pins.sh.
#
# One definition of "the pinned contents": the gitlink `git ls-tree HEAD` records, and
# `git archive` of exactly that commit out of the submodule. A submodule worktree at some
# other commit, or a dirty one, never enters the answer.
#
# Not executable on its own; both callers run with `set -euo pipefail`, which the archive
# pipeline relies on to fail when either git or tar does.

# pin_of ROOT SUBMODULE -> the commit ROOT's HEAD records for the gitlink (empty if none).
pin_of() {
    git -C "$1" ls-tree HEAD -- "$2" | awk '{print $3}'
}

# archive_pin ROOT SUBMODULE PIN DEST -> DEST holds exactly PIN's tree.
# DEST is replaced so a file deleted between pins cannot survive from an earlier run.
archive_pin() {
    rm -rf -- "$4"
    mkdir -p -- "$4"
    git -C "$1/$2" archive --format=tar "$3" | tar -x -C "$4"
}
