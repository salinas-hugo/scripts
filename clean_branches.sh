#!/usr/bin/env bash
#
# clean_branches.sh
#
# Checks local git branches and identifies which ones have already been
# merged to main/master (including squash and rebase PR merges via gh CLI).
# The goal: keep only branches that are genuinely WIP locally.
#
# Usage:
#   ./clean_branches.sh [directory] [--dry-run | --delete]
#
#   ./clean_branches.sh                    # current dir, ask before deleting
#   ./clean_branches.sh /path/to/repo      # target repo, ask before deleting
#   ./clean_branches.sh --dry-run          # show status only, never delete
#   ./clean_branches.sh /path/to/repo --delete

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
err()  { echo -e "${RED}error:${NC} $*" >&2; }
info() { echo -e "${CYAN}${BOLD}$*${NC}"; }
dim()  { echo -e "${DIM}$*${NC}"; }

usage() {
    echo "Usage: $(basename "$0") [directory] [--dry-run | --delete]"
    echo
    echo "  directory   Path to git repository (default: current directory)"
    echo "  --dry-run   Show merged/WIP branches, never delete"
    echo "  --delete    Show merged/WIP branches and delete without prompting"
    exit 1
}

# ── Argument parsing ──────────────────────────────────────────────────────────
DRY_RUN=false
AUTO_DELETE=false
REPO_DIR=""

for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=true ;;
        --delete)   AUTO_DELETE=true ;;
        -h|--help)  usage ;;
        *)
            if [[ -n "$REPO_DIR" ]]; then
                err "Unknown argument: $arg"
                usage
            fi
            REPO_DIR="$arg"
            ;;
    esac
done

# ── Change to target directory ────────────────────────────────────────────────
if [[ -n "$REPO_DIR" ]]; then
    if [[ ! -d "$REPO_DIR" ]]; then
        err "Directory does not exist: $REPO_DIR"
        exit 1
    fi
    cd "$REPO_DIR"
fi

# ── Sanity checks ─────────────────────────────────────────────────────────────
if ! git rev-parse --git-dir &>/dev/null; then
    err "Not inside a git repository."
    exit 1
fi

# ── Detect default branch ─────────────────────────────────────────────────────
detect_default_branch() {
    # 1. Try the remote's HEAD pointer (most reliable)
    local remote_head
    remote_head=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || true
    [[ -n "$remote_head" ]] && { echo "$remote_head"; return; }

    # 2. Fall back to well-known names that exist locally
    for name in main master; do
        git rev-parse --verify "$name" &>/dev/null && { echo "$name"; return; }
    done

    echo ""
}

DEFAULT_BRANCH=$(detect_default_branch)
if [[ -z "$DEFAULT_BRANCH" ]]; then
    err "Could not detect default branch (main/master). Ensure origin/HEAD is set."
    exit 1
fi

CURRENT_BRANCH=$(git branch --show-current)

# ── Collect worktree-locked branches ──────────────────────────────────────────
# Parallel arrays (bash 3.2-compatible — no associative arrays)
WORKTREE_BRANCH_NAMES=()
WORKTREE_PATHS=()

while IFS= read -r line; do
    if [[ "$line" == worktree\ * ]]; then
        wt_path="${line#worktree }"
    elif [[ "$line" == branch\ refs/heads/* ]]; then
        branch_name="${line#branch refs/heads/}"
        WORKTREE_BRANCH_NAMES+=("$branch_name")
        WORKTREE_PATHS+=("$wt_path")
    fi
done < <(git worktree list --porcelain)

is_checked_out() {
    local branch="$1"
    for wt_branch in "${WORKTREE_BRANCH_NAMES[@]+"${WORKTREE_BRANCH_NAMES[@]}"}"; do
        [[ "$wt_branch" == "$branch" ]] && return 0
    done
    return 1
}

get_worktree_path() {
    local branch="$1"
    for i in "${!WORKTREE_BRANCH_NAMES[@]}"; do
        [[ "${WORKTREE_BRANCH_NAMES[$i]}" == "$branch" ]] && echo "${WORKTREE_PATHS[$i]}" && return
    done
}

# ── Detect GitHub CLI + remote ────────────────────────────────────────────────
HAS_GH=false
REPO_SLUG=""

if command -v gh &>/dev/null; then
    REPO_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
    [[ -n "$REPO_SLUG" ]] && HAS_GH=true
fi

# ── Print header ──────────────────────────────────────────────────────────────
echo
info "Branch cleanup — $(git rev-parse --show-toplevel | xargs basename)"
dim "  Default branch : $DEFAULT_BRANCH"
dim "  Current branch : $CURRENT_BRANCH"
if $HAS_GH; then
    dim "  GitHub repo    : $REPO_SLUG  (gh CLI active — squash/rebase merges detected)"
else
    dim "  GitHub CLI     : not available — only regular merges detected via git"
fi
echo

# ── Collect all local branches except the default ─────────────────────────────
ALL_BRANCHES=()
while IFS= read -r branch; do
    ALL_BRANCHES+=("$branch")
done < <(git branch --format='%(refname:short)' | grep -v "^${DEFAULT_BRANCH}$")

if [[ ${#ALL_BRANCHES[@]} -eq 0 ]]; then
    echo "No local branches besides '${DEFAULT_BRANCH}'."
    exit 0
fi

# Pre-fetch merged branches via git (fast, single call, no network)
GIT_MERGED=()
while IFS= read -r branch; do
    GIT_MERGED+=("$branch")
done < <(
    git branch --merged "$DEFAULT_BRANCH" --format='%(refname:short)' \
    | grep -v "^${DEFAULT_BRANCH}$"
)

# ── Classify each branch ──────────────────────────────────────────────────────
MERGED_BRANCHES=()
MERGED_HOW=()
WIP_BRANCHES=()

for branch in "${ALL_BRANCHES[@]}"; do
    merged=false
    how=""

    # 1. Regular merge check (fast, no network)
    for mb in "${GIT_MERGED[@]+"${GIT_MERGED[@]}"}"; do
        if [[ "$mb" == "$branch" ]]; then
            merged=true
            how="git merge"
            break
        fi
    done

    # 2. PR check via gh (covers squash + rebase merges)
    if ! $merged && $HAS_GH; then
        pr_number=$(
            gh pr list \
                --head "$branch" \
                --state merged \
                --json number \
                --jq '.[0].number' \
                2>/dev/null || true
        )
        if [[ -n "$pr_number" && "$pr_number" != "null" ]]; then
            merged=true
            how="PR #${pr_number}"
        fi
    fi

    if $merged; then
        MERGED_BRANCHES+=("$branch")
        MERGED_HOW+=("$how")
    else
        WIP_BRANCHES+=("$branch")
    fi
done

# ── Display results ───────────────────────────────────────────────────────────
echo -e "${GREEN}${BOLD}Merged — safe to delete (${#MERGED_BRANCHES[@]})${NC}"
if [[ ${#MERGED_BRANCHES[@]} -eq 0 ]]; then
    dim "  (none)"
else
    for i in "${!MERGED_BRANCHES[@]}"; do
        branch="${MERGED_BRANCHES[$i]}"
        how="${MERGED_HOW[$i]}"
        suffix=""
        if [[ "$branch" == "$CURRENT_BRANCH" ]]; then
            suffix="${DIM} ← current, will skip${NC}"
        elif is_checked_out "$branch"; then
            suffix="${DIM} ← worktree: $(get_worktree_path "$branch"), will remove worktree${NC}"
        fi
        printf "  ${GREEN}✓${NC}  %-45s ${DIM}via %s${NC}%b\n" "$branch" "$how" "$suffix"
    done
fi

echo
echo -e "${YELLOW}${BOLD}WIP — not merged (${#WIP_BRANCHES[@]})${NC}"
if [[ ${#WIP_BRANCHES[@]} -eq 0 ]]; then
    dim "  (none)"
else
    for branch in "${WIP_BRANCHES[@]}"; do
        suffix=""
        [[ "$branch" == "$CURRENT_BRANCH" ]] && suffix="${DIM} ← current${NC}"
        printf "  ${YELLOW}○${NC}  %s%b\n" "$branch" "$suffix"
    done
fi

echo

# ── Delete merged branches ────────────────────────────────────────────────────
if [[ ${#MERGED_BRANCHES[@]} -eq 0 ]]; then
    echo "Nothing to delete."
    exit 0
fi

if $DRY_RUN; then
    dim "(dry-run — no branches deleted)"
    exit 0
fi

do_delete=false
if $AUTO_DELETE; then
    do_delete=true
else
    read -rp "Delete all merged branches? [y/N] " answer
    [[ "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" == "y" ]] && do_delete=true
fi

if ! $do_delete; then
    dim "Skipped — no branches deleted."
    exit 0
fi

echo
for i in "${!MERGED_BRANCHES[@]}"; do
    branch="${MERGED_BRANCHES[$i]}"
    how="${MERGED_HOW[$i]}"

    if [[ "$branch" == "$CURRENT_BRANCH" ]]; then
        echo -e "  ${YELLOW}skip${NC}    $branch  ${DIM}(checked out — switch away first)${NC}"
        continue
    fi

    if is_checked_out "$branch"; then
        wt_path=$(get_worktree_path "$branch")
        if git worktree remove --force "$wt_path" 2>/dev/null; then
            echo -e "  ${CYAN}removed worktree${NC}  $wt_path"
        else
            echo -e "  ${RED}failed${NC}   $branch  ${DIM}(could not remove worktree: $wt_path)${NC}"
            continue
        fi
    fi

    if git branch -d "$branch" 2>/dev/null; then
        echo -e "  ${GREEN}deleted${NC}  $branch"
    else
        # -d refuses unmerged-by-git branches (squash/rebase); use -D since
        # we've already confirmed it was merged via PR
        if git branch -D "$branch" 2>/dev/null; then
            echo -e "  ${GREEN}deleted${NC}  $branch  ${DIM}(forced — $how)${NC}"
        else
            echo -e "  ${RED}failed${NC}   $branch"
        fi
    fi
done

echo
info "Done."
