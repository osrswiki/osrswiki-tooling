#!/bin/bash
set -euo pipefail

# Project the private Fleet Sync checkout into the public android, iOS, and
# tooling trees. Each projector already no-ops when the staged tree matches
# public main. Run this from the primary checkout on private main after land.
# This is not TestFlight or Play upload.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=color-utils.sh
source "$SCRIPT_DIR/color-utils.sh"
# shellcheck source=find-git-repo.sh
source "$SCRIPT_DIR/find-git-repo.sh"

CURRENT_PHASE="Initialization"
print_header "OSRS Wiki public tree publish"
echo "Date: $(date)"
echo ""

if ! GIT_ROOT="$(find_git_repo "$(pwd)")" || [[ ! -f "$GIT_ROOT/AGENTS.md" ]]; then
    print_error "Must run from the OSRS Wiki Fleet Sync checkout"
    echo "Current directory: $(pwd)"
    exit 1
fi

git_dir="$(cd "$GIT_ROOT" && git rev-parse --git-dir)"
common_dir="$(cd "$GIT_ROOT" && git rev-parse --git-common-dir)"
if [[ "$git_dir" != "$common_dir" ]]; then
    print_error "Run from the primary checkout on private main, not a linked worktree"
    echo "Checkout: $GIT_ROOT"
    exit 1
fi

branch="$(cd "$GIT_ROOT" && git rev-parse --abbrev-ref HEAD)"
if [[ "$branch" != "main" && "$branch" != "master" ]]; then
    print_error "Run from private main after land (current branch: $branch)"
    exit 1
fi

cd "$GIT_ROOT"
print_success "Publishing public trees from $GIT_ROOT ($branch)"

status=0
for projector in deploy-android.sh deploy-ios.sh deploy-tooling.sh; do
    CURRENT_PHASE="$projector"
    print_phase "Running $projector"
    if ! "$GIT_ROOT/scripts/shared/$projector"; then
        print_error "$projector failed"
        status=1
        break
    fi
done

if [[ "$status" -ne 0 ]]; then
    exit "$status"
fi

print_success "Public android, iOS, and tooling projectors finished"
print_info "Trees whose projected content matched public main were left unchanged"
