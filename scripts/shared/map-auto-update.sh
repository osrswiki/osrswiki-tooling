#!/bin/bash
set -euo pipefail

# Single entry point for automatic OSRS map asset updates.
# Checks OpenRS2, regenerates surface + underground assets, compares bytes
# against the current pins, and (unless --dry-run) publishes NEW versioned
# tooling releases and opens a pin-bump PR. Never clobbers or deletes an
# existing release.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/osrs_map_auto_update.py"
SURFACE_PUBLISH="$SCRIPT_DIR/publish-map-release-bundle.sh"
UNDERGROUND_PUBLISH="$SCRIPT_DIR/publish-underground-release-assets.sh"
BUNDLE_HELPER="$SCRIPT_DIR/osrs_map_release_bundle.py"
FETCH_SURFACE="$SCRIPT_DIR/fetch-map-release-assets.sh"
FETCH_UNDERGROUND="$SCRIPT_DIR/fetch-underground-release-assets.sh"

usage() {
    cat >&2 <<'EOF'
usage:
  map-auto-update.sh [--dry-run] [--force] [--skip-generate] [--skip-pr]
      [--skip-underground-rebuild]

  --dry-run                   Generate and compare; do not upload or open a PR
  --force                     Regenerate even if pins already record this cache
  --skip-generate             Reuse host-local generated assets (no dump)
  --skip-pr                   Publish releases if needed, but do not open a PR
  --skip-underground-rebuild  Compare/publish underground from an existing tree
                              at OSRS_UNDERGROUND_GENERATED_DIR if set; otherwise
                              treat underground as unchanged when rebuild inputs
                              cannot be assembled

Idempotent. Safe to re-run. Failures exit nonzero and leave a log; humans hear
about results via the pin PR or a GitHub issue, not email or chat.
EOF
    exit 2
}

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

open_or_comment_issue() {
    local title="$1"
    local search="$2"
    local body_file="$3"
    if [[ "$dry_run" -eq 1 ]]; then
        log "dry-run: would open or comment GitHub issue: $title"
        return 0
    fi
    if ! command -v gh >/dev/null 2>&1; then
        log "gh is unavailable; cannot open issue: $title"
        return 0
    fi
    local existing
    existing="$(gh issue list --repo "$FLEET_REPO" --search "$search" --state open \
        --json number --jq '.[0].number // empty' || true)"
    if [[ -n "$existing" ]]; then
        gh issue comment "$existing" --repo "$FLEET_REPO" --body-file "$body_file" || true
        log "commented on GitHub issue #$existing"
    else
        gh issue create --repo "$FLEET_REPO" --title "$title" --body-file "$body_file" || true
        log "opened GitHub issue: $title"
    fi
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        die "required command is unavailable: $1"
    fi
}

file_sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

file_size() {
    if stat -f '%z' "$1" >/dev/null 2>&1; then
        stat -f '%z' "$1"
    else
        stat -c '%s' "$1"
    fi
}

release_exists() {
    local repo="$1"
    local tag="$2"
    gh release view "$tag" --repo "$repo" --json tagName >/dev/null 2>&1
}

remote_bundle_matches() {
    local repo="$1"
    local tag="$2"
    local name="$3"
    local bytes="$4"
    local remote
    remote="$(gh release view "$tag" --repo "$repo" --json assets 2>/dev/null \
        | jq -r --arg name "$name" '.assets[] | select(.name == $name) | .size' \
        | tail -n1 || true)"
    [[ "$remote" == "$bytes" ]]
}

dry_run=0
force=0
skip_generate=0
skip_pr=0
skip_underground_rebuild=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dry_run=1; shift ;;
        --force) force=1; shift ;;
        --skip-generate) skip_generate=1; shift ;;
        --skip-pr) skip_pr=1; shift ;;
        --skip-underground-rebuild) skip_underground_rebuild=1; shift ;;
        -h|--help) usage ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage ;;
    esac
done

# shellcheck source=find-git-repo.sh
source "$SCRIPT_DIR/find-git-repo.sh"
osrs_load_local_storage_config
if ! GIT_ROOT="$(find_git_repo "$(pwd)")" || [[ ! -f "$GIT_ROOT/AGENTS.md" ]]; then
    die "must run from an OSRS Wiki Fleet Sync checkout or assigned worktree"
fi
[[ -f "$GIT_ROOT/.osrs-artifacts.env" ]] && source "$GIT_ROOT/.osrs-artifacts.env"
CACHE_BASE="${OSRS_CACHE_ROOT:-$(get_cache_dir)}"
SURFACE_DIR="${OSRS_MAP_ASSET_SOURCE_DIR:-$CACHE_BASE/binary-assets/mbtiles}"
STATE_DIR="$CACHE_BASE/map-auto-update"
LAST_RUN="$STATE_DIR/last-run.json"
WORK_DIR="$STATE_DIR/work"
SURFACE_MANIFEST="$GIT_ROOT/shared/manifests/osrs-map-assets-v1.json"
UNDERGROUND_MANIFEST="$GIT_ROOT/shared/manifests/osrs-underground-assets-v1.json"
PIXI_MANIFEST="$GIT_ROOT/tools/pixi.toml"
FLEET_REPO="omiyawaki/osrswiki-fleet"
TOOLING_REPO="osrswiki/osrswiki-tooling"

require_command python3
require_command jq
require_command pixi
if [[ -z "${JAVA_HOME:-}" ]]; then
    for java_home in \
        /opt/homebrew/opt/openjdk@25/libexec/openjdk.jdk/Contents/Home \
        /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home
    do
        if [[ -x "$java_home/bin/java" ]]; then
            export JAVA_HOME="$java_home"
            break
        fi
    done
fi
if [[ -n "${JAVA_HOME:-}" ]]; then
    export PATH="$JAVA_HOME/bin:$PATH"
fi
mkdir -p "$STATE_DIR" "$WORK_DIR" "$SURFACE_DIR"

log "map-auto-update starting (dry_run=$dry_run force=$force skip_generate=$skip_generate)"
log "checkout: $GIT_ROOT"
log "cache: $CACHE_BASE"

LIVE_CACHE_JSON="$WORK_DIR/live-cache.json"
pixi run --manifest-path "$PIXI_MANIFEST" --locked -- python \
    "$GIT_ROOT/tools/map/print_latest_openrs2_cache.py" > "$LIVE_CACHE_JSON"
LIVE_ID="$(jq -r '.id' "$LIVE_CACHE_JSON")"
LIVE_TS="$(jq -r '.timestamp // empty' "$LIVE_CACHE_JSON")"
LIVE_BUILD="$(jq -r '.build // empty' "$LIVE_CACHE_JSON")"
XTEA_ID="$(jq -r '.xtea_cache_id // .id' "$LIVE_CACHE_JSON")"
log "live OpenRS2 cache id=$LIVE_ID timestamp=$LIVE_TS build=$LIVE_BUILD xtea_cache_id=$XTEA_ID"

DECIDE_PRE="$WORK_DIR/decide-pre"
rm -rf "$DECIDE_PRE"
mkdir -p "$DECIDE_PRE"
decide_pre_args=(
    python3 "$HELPER" decide
    --live-cache "$LIVE_CACHE_JSON"
    --surface-manifest "$SURFACE_MANIFEST"
    --underground-manifest "$UNDERGROUND_MANIFEST"
    --output "$DECIDE_PRE"
)
if [[ "$force" -eq 1 ]]; then
    decide_pre_args+=(--force)
fi
PRE_PLAN="$DECIDE_PRE/plan.json"
"${decide_pre_args[@]}" > /dev/null
NEED_GENERATE="$(jq -r '.need_generate' "$PRE_PLAN")"
log "freshness need_generate=$NEED_GENERATE"

if [[ "$NEED_GENERATE" != "true" && "$skip_generate" -ne 1 && "$force" -ne 1 ]]; then
    log "pins already record OpenRS2 cache $LIVE_ID; nothing to do"
    jq -n --argjson live "$(cat "$LIVE_CACHE_JSON")" --arg decision "up_to_date" \
        '{live_cache_id: ($live.id|tonumber), decision: $decision, timestamp: (now|todateiso8601)}' \
        > "$LAST_RUN"
    exit 0
fi

SURFACE_PIN_CACHE_ID="$(jq -r '.provenance.openrs2_cache_id // empty' "$SURFACE_MANIFEST")"
UNDERGROUND_PIN_CACHE_ID="$(jq -r '.provenance.openrs2_cache_id // empty' "$UNDERGROUND_MANIFEST")"
if [[ -f "$LAST_RUN" && "$force" -ne 1 && "$skip_generate" -ne 1 ]]; then
    LAST_ID="$(jq -r '.live_cache_id // empty' "$LAST_RUN")"
    LAST_DECISION="$(jq -r '.decision // empty' "$LAST_RUN")"
    pins_record_live=0
    if [[ "$SURFACE_PIN_CACHE_ID" == "$LIVE_ID" && "$UNDERGROUND_PIN_CACHE_ID" == "$LIVE_ID" ]]; then
        pins_record_live=1
    fi
    if [[ "$LAST_ID" == "$LIVE_ID" && "$LAST_DECISION" == "unchanged" && "$pins_record_live" -eq 1 ]]; then
        log "last-run already compared cache $LIVE_ID and found no content change"
        exit 0
    fi
    if [[ "$LAST_ID" == "$LIVE_ID" && "$LAST_DECISION" == "published" && "$pins_record_live" -eq 1 ]]; then
        log "last-run already published cache $LIVE_ID; not regenerating"
        exit 0
    fi
    if [[ "$LAST_ID" == "$LIVE_ID" && ( "$LAST_DECISION" == "published" || "$LAST_DECISION" == "unchanged" ) && "$pins_record_live" -ne 1 ]]; then
        log "last-run recorded $LAST_DECISION for cache $LIVE_ID but a pin is still stale (surface=$SURFACE_PIN_CACHE_ID underground=$UNDERGROUND_PIN_CACHE_ID); continuing"
    fi
fi

UNDERGROUND_DIR="${OSRS_UNDERGROUND_GENERATED_DIR:-$STATE_DIR/underground-generated}"
DUMPER_OUTPUT="$CACHE_BASE/binary-assets/map-images/output"
mkdir -p "$DUMPER_OUTPUT"

if [[ "$skip_generate" -ne 1 ]]; then
    log "regenerating surface floors from OpenRS2 cache $LIVE_ID"
    export OSRS_MAP_COMMAND_TIMEOUT="${OSRS_MAP_COMMAND_TIMEOUT:-21600}"
    export OSRS_MAP_STREAM_OUTPUT="${OSRS_MAP_STREAM_OUTPUT:-1}"
    export OSRS_CACHE_ROOT="$CACHE_BASE"
    log "JAVA_HOME=${JAVA_HOME:-unset}"
    pixi run --manifest-path "$PIXI_MANIFEST" --locked -- python \
        "$GIT_ROOT/tools/map/map-asset-generator.py" --force --render-provenance
    log "surface generation finished"
fi

[[ -f "$SURFACE_DIR/map_floor_0.mbtiles" ]] || die "surface mbtiles missing in $SURFACE_DIR"

REGION_STATS="${OSRS_MAP_REGION_STATS:-$DUMPER_OUTPUT/region-load-stats.json}"
MAX_TERRAIN_ONLY_FALLBACK="${OSRS_MAP_TERRAIN_ONLY_FALLBACK_MAX:-8}"
if [[ "$skip_generate" -ne 1 ]]; then
    [[ -f "$REGION_STATS" ]] || die "region-load-stats.json missing after dump: $REGION_STATS"
fi
if [[ -f "$REGION_STATS" ]]; then
    REGION_STATS_EVAL="$WORK_DIR/region-stats-eval.json"
    set +e
    python3 "$HELPER" region-stats --stats "$REGION_STATS" \
        --max-fallback "$MAX_TERRAIN_ONLY_FALLBACK" \
        > "$REGION_STATS_EVAL"
    region_stats_status=$?
    set -e
    [[ "$region_stats_status" -eq 0 || "$region_stats_status" -eq 2 ]] \
        || die "region-stats evaluation failed"
    log "region-load-stats $(jq -c '{regions_loaded,locations_loaded,terrain_only_fallback,unnamed_xtea_applied,unnamed_xtea_keys_available,ok}' "$REGION_STATS_EVAL")"
    if [[ "$region_stats_status" -eq 2 ]]; then
        ISSUE_BODY="$WORK_DIR/terrain-only-fallback-issue.md"
        {
            echo "Weekly map-auto-update refused to publish because MAPS file-1 (locations)"
            echo "failed for too many regions. Those regions would ship terrain-only and drop buildings."
            echo
            echo "- OpenRS2 cache id: \`$LIVE_ID\`"
            echo "- timestamp: \`$LIVE_TS\`"
            echo "- build: \`$LIVE_BUILD\`"
            echo "- checkout: \`$GIT_ROOT\`"
            echo "- max terrain-only fallback: \`$MAX_TERRAIN_ONLY_FALLBACK\`"
            echo
            echo '```json'
            cat "$REGION_STATS_EVAL"
            echo '```'
            echo
            echo "Sample fallback region ids:"
            jq -r '.fallback_region_ids // [] | map(tostring) | join(", ")' "$REGION_STATS_EVAL"
        } > "$ISSUE_BODY"
        open_or_comment_issue \
            "map-auto-update: terrain-only location fallbacks" \
            "in:title map-auto-update: terrain-only location fallbacks" \
            "$ISSUE_BODY"
        die "terrain-only location fallbacks exceed $MAX_TERRAIN_ONLY_FALLBACK; not publishing"
    fi
else
    log "region-load-stats.json not present; skip-generate without a prior dump report"
fi

UNDERGROUND_REBUILD_STATUS="skipped"
if [[ "$skip_underground_rebuild" -eq 1 ]]; then
    log "skipping underground rebuild (--skip-underground-rebuild)"
    if [[ ! -d "$UNDERGROUND_DIR" ]]; then
        UNDERGROUND_DIR="$WORK_DIR/underground-from-pin"
        mkdir -p "$UNDERGROUND_DIR"
        "$FETCH_UNDERGROUND" materialize "$UNDERGROUND_MANIFEST" "$UNDERGROUND_DIR"
        UNDERGROUND_REBUILD_STATUS="pinned_copy"
    fi
else
    log "exporting underground inventory and alignment from the live cache"
    if "$SCRIPT_DIR/map-auto-update-underground.sh" \
        --git-root "$GIT_ROOT" \
        --cache-base "$CACHE_BASE" \
        --live-cache "$LIVE_CACHE_JSON" \
        --output "$UNDERGROUND_DIR" \
        --prior-manifest "$UNDERGROUND_MANIFEST"; then
        UNDERGROUND_REBUILD_STATUS="rebuilt"
        log "underground rebuild finished: $UNDERGROUND_DIR"
    else
        UNDERGROUND_REBUILD_STATUS="failed"
        log "underground rebuild failed; using the current pin for comparison"
        UNDERGROUND_DIR="$WORK_DIR/underground-from-pin"
        rm -rf "$UNDERGROUND_DIR"
        mkdir -p "$UNDERGROUND_DIR"
        "$FETCH_UNDERGROUND" materialize "$UNDERGROUND_MANIFEST" "$UNDERGROUND_DIR"
        ISSUE_BODY="$WORK_DIR/underground-rebuild-issue.md"
        {
            echo "Weekly map-auto-update could not rebuild underground assets from the live cache."
            echo
            echo "- OpenRS2 cache id: \`$LIVE_ID\`"
            echo "- timestamp: \`$LIVE_TS\`"
            echo "- build: \`$LIVE_BUILD\`"
            echo "- checkout: \`$GIT_ROOT\`"
            echo
            echo "The current underground pin was kept for comparison. Surface still proceeds."
            echo "This issue is reused (not opened weekly) until the rebuild succeeds."
        } > "$ISSUE_BODY"
        open_or_comment_issue \
            "map-auto-update: underground rebuild failed" \
            "in:title map-auto-update: underground rebuild failed" \
            "$ISSUE_BODY"
    fi
fi

BUNDLE_ZIP="$WORK_DIR/map_floors.zip"
"$FETCH_SURFACE" build-bundle "$SURFACE_MANIFEST" "$SURFACE_DIR" "$BUNDLE_ZIP" || {
    # build-bundle verifies against the CURRENT pin; a changed tree fails that.
    # Pack directly when the generated floors no longer match the old pin.
    python3 "$BUNDLE_HELPER" pack "$SURFACE_DIR" "$BUNDLE_ZIP"
}
BUNDLE_JSON="$WORK_DIR/surface-bundle.json"
DIGEST_LINE="$(python3 "$BUNDLE_HELPER" digest "$BUNDLE_ZIP")"
printf '{"sha256":"%s","bytes":%s}\n' \
    "${DIGEST_LINE%%$'\t'*}" "${DIGEST_LINE#*$'\t'}" > "$BUNDLE_JSON"

PINNED_SURFACE_DIR="$WORK_DIR/surface-from-pin"
PINNED_UNDERGROUND_DIR="$WORK_DIR/underground-from-pin-compare"
mkdir -p "$PINNED_SURFACE_DIR" "$PINNED_UNDERGROUND_DIR"
if python3 "$HELPER" pin-dir --manifest "$SURFACE_MANIFEST" \
        --source-dir "$PINNED_SURFACE_DIR" --key name >/dev/null; then
    log "reusing cached surface pin for payload comparison"
else
    log "materializing the current surface pin for payload comparison"
    rm -rf "$PINNED_SURFACE_DIR"
    mkdir -p "$PINNED_SURFACE_DIR"
    "$FETCH_SURFACE" materialize "$SURFACE_MANIFEST" "$PINNED_SURFACE_DIR"
fi
if python3 "$HELPER" pin-dir --manifest "$UNDERGROUND_MANIFEST" \
        --source-dir "$PINNED_UNDERGROUND_DIR" --key path >/dev/null; then
    log "reusing cached underground pin for payload comparison"
else
    log "materializing the current underground pin for payload comparison"
    rm -rf "$PINNED_UNDERGROUND_DIR"
    mkdir -p "$PINNED_UNDERGROUND_DIR"
    "$FETCH_UNDERGROUND" materialize "$UNDERGROUND_MANIFEST" "$PINNED_UNDERGROUND_DIR"
fi

EXISTING_SURFACE_ARGS=()
EXISTING_UNDERGROUND_ARGS=()
SURFACE_RECORDS_JSON="$WORK_DIR/surface-records.json"
python3 "$HELPER" records --kind surface --source-dir "$SURFACE_DIR" > "$SURFACE_RECORDS_JSON"
SURFACE_FP="$(python3 "$HELPER" fingerprint --records "$SURFACE_RECORDS_JSON")"
SURFACE_TAG="map-assets-v1-$SURFACE_FP"
UNDERGROUND_RECORDS_JSON="$WORK_DIR/underground-records.json"
python3 "$HELPER" records --kind underground --source-dir "$UNDERGROUND_DIR" \
    > "$UNDERGROUND_RECORDS_JSON"
UNDERGROUND_FP="$(python3 "$HELPER" fingerprint --records "$UNDERGROUND_RECORDS_JSON")"
UNDERGROUND_TAG="underground-assets-v1-$UNDERGROUND_FP"

if command -v gh >/dev/null 2>&1; then
    if release_exists "$TOOLING_REPO" "$SURFACE_TAG"; then
        EXISTING_SURFACE_ARGS+=(--existing-surface-tag)
        SURFACE_BYTES="$(jq -r '.bytes' "$BUNDLE_JSON")"
        if remote_bundle_matches "$TOOLING_REPO" "$SURFACE_TAG" "map_floors.zip" "$SURFACE_BYTES"; then
            EXISTING_SURFACE_ARGS+=(--existing-surface-matches)
        fi
    fi
    if release_exists "$TOOLING_REPO" "$UNDERGROUND_TAG"; then
        EXISTING_UNDERGROUND_ARGS+=(--existing-underground-tag)
        # Matching is decided per-asset at upload time; treat presence as a
        # reuse candidate only when the tag already exists.
        EXISTING_UNDERGROUND_ARGS+=(--existing-underground-matches)
    fi
fi

DECIDE_DIR="$WORK_DIR/decide"
rm -rf "$DECIDE_DIR"
mkdir -p "$DECIDE_DIR"
decide_args=(
    python3 "$HELPER" decide
    --live-cache "$LIVE_CACHE_JSON"
    --surface-manifest "$SURFACE_MANIFEST"
    --underground-manifest "$UNDERGROUND_MANIFEST"
    --surface-dir "$SURFACE_DIR"
    --underground-dir "$UNDERGROUND_DIR"
    --surface-bundle "$BUNDLE_JSON"
    --pinned-surface-dir "$PINNED_SURFACE_DIR"
    --pinned-underground-dir "$PINNED_UNDERGROUND_DIR"
    --output "$DECIDE_DIR"
    --force
)
if [[ ${#EXISTING_SURFACE_ARGS[@]} -gt 0 ]]; then
    decide_args+=("${EXISTING_SURFACE_ARGS[@]}")
fi
if [[ ${#EXISTING_UNDERGROUND_ARGS[@]} -gt 0 ]]; then
    decide_args+=("${EXISTING_UNDERGROUND_ARGS[@]}")
fi
"${decide_args[@]}" > /dev/null

PLAN="$DECIDE_DIR/plan.json"
SURFACE_ACTION="$(jq -r '.surface.action' "$PLAN")"
UNDERGROUND_ACTION="$(jq -r '.underground.action' "$PLAN")"
OPEN_PR="$(jq -r '.open_pr' "$PLAN")"
log "plan surface=$SURFACE_ACTION underground=$UNDERGROUND_ACTION open_pr=$OPEN_PR rebuild=$UNDERGROUND_REBUILD_STATUS"
jq -r '.pr_body // empty' "$PLAN" | sed '/^$/d' | head -n 40 || true

if [[ "$UNDERGROUND_REBUILD_STATUS" == "failed" && "$SURFACE_ACTION" != "skip" ]]; then
    log "surface map changed but underground rebuild failed"
fi

if [[ "$OPEN_PR" != "true" ]]; then
    log "generated assets match the current pins; no release and no PR"
    jq -n --argjson live "$(cat "$LIVE_CACHE_JSON")" --arg decision "unchanged" \
        --arg surface_fp "$SURFACE_FP" --arg underground_fp "$UNDERGROUND_FP" \
        '{
            live_cache_id: ($live.id|tonumber),
            decision: $decision,
            surface_fingerprint: $surface_fp,
            underground_fingerprint: $underground_fp,
            timestamp: (now|todateiso8601)
        }' > "$LAST_RUN"
    exit 0
fi

if [[ "$dry_run" -eq 1 ]]; then
    log "dry-run: would publish and open a pin PR (no upload, no PR)"
    jq '{surface, underground, open_pr, pr_title, live_cache_id, live_cache_timestamp}' "$PLAN"
    exit 0
fi

require_command gh
if [[ "$SURFACE_ACTION" == "create" || "$SURFACE_ACTION" == "reuse" ]]; then
    NEW_SURFACE_MANIFEST="$DECIDE_DIR/osrs-map-assets-v1.json"
    [[ -f "$NEW_SURFACE_MANIFEST" ]] || die "missing generated surface manifest"
    "$SURFACE_PUBLISH" --create-release \
        --manifest "$NEW_SURFACE_MANIFEST" \
        --source-dir "$SURFACE_DIR" \
        --output "$BUNDLE_ZIP" \
        --release-notes "$DECIDE_DIR/pr-body.md"
fi
if [[ "$UNDERGROUND_ACTION" == "create" || "$UNDERGROUND_ACTION" == "reuse" ]]; then
    if [[ "$UNDERGROUND_REBUILD_STATUS" != "rebuilt" && "$UNDERGROUND_REBUILD_STATUS" != "skipped" ]]; then
        die "refusing to publish underground assets that were not rebuilt"
    fi
    NEW_UNDERGROUND_MANIFEST="$DECIDE_DIR/osrs-underground-assets-v1.json"
    [[ -f "$NEW_UNDERGROUND_MANIFEST" ]] || die "missing generated underground manifest"
    "$UNDERGROUND_PUBLISH" --create-release \
        --manifest "$NEW_UNDERGROUND_MANIFEST" \
        --source-dir "$UNDERGROUND_DIR" \
        --release-notes "$DECIDE_DIR/pr-body.md"
fi

if [[ "$skip_pr" -eq 1 ]]; then
    log "skip-pr: releases published; pin branch not opened"
    jq -n --argjson live "$(cat "$LIVE_CACHE_JSON")" --arg decision "published" \
        --arg surface_fp "$SURFACE_FP" --arg underground_fp "$UNDERGROUND_FP" \
        '{
            live_cache_id: ($live.id|tonumber),
            decision: $decision,
            surface_fingerprint: $surface_fp,
            underground_fingerprint: $underground_fp,
            timestamp: (now|todateiso8601)
        }' > "$LAST_RUN"
    exit 0
fi

PIN_BRANCH="map-pins/${SURFACE_FP}-${UNDERGROUND_FP}"
PIN_WORKTREE="$STATE_DIR/pin-worktree-${SURFACE_FP}"
if git -C "$GIT_ROOT" worktree list --porcelain | grep -q "branch refs/heads/$PIN_BRANCH"; then
    die "pin worktree/branch $PIN_BRANCH already exists"
fi
git -C "$GIT_ROOT" fetch origin main
rm -rf "$PIN_WORKTREE"
git -C "$GIT_ROOT" worktree add "$PIN_WORKTREE" -B "$PIN_BRANCH" origin/main
if [[ -f "$DECIDE_DIR/osrs-map-assets-v1.json" ]]; then
    cp "$DECIDE_DIR/osrs-map-assets-v1.json" \
        "$PIN_WORKTREE/shared/manifests/osrs-map-assets-v1.json"
fi
if [[ -f "$DECIDE_DIR/osrs-underground-assets-v1.json" ]]; then
    cp "$DECIDE_DIR/osrs-underground-assets-v1.json" \
        "$PIN_WORKTREE/shared/manifests/osrs-underground-assets-v1.json"
fi
git -C "$PIN_WORKTREE" add shared/manifests/osrs-map-assets-v1.json \
    shared/manifests/osrs-underground-assets-v1.json
if git -C "$PIN_WORKTREE" diff --cached --quiet; then
    log "pin worktree has no manifest changes"
else
    git -C "$PIN_WORKTREE" commit -m "$(jq -r '.pr_title' "$PLAN")"
    git -C "$PIN_WORKTREE" push -u origin "$PIN_BRANCH"
    EXISTING_PR="$(gh pr list --repo "$FLEET_REPO" --head "$PIN_BRANCH" --json number --jq '.[0].number // empty')"
    if [[ -n "$EXISTING_PR" ]]; then
        log "pin PR already open: #$EXISTING_PR"
    else
        gh pr create --repo "$FLEET_REPO" --base main --head "$PIN_BRANCH" \
            --title "$(jq -r '.pr_title' "$PLAN")" \
            --body-file "$DECIDE_DIR/pr-body.md"
    fi
fi
git -C "$GIT_ROOT" worktree remove --force "$PIN_WORKTREE"

jq -n --argjson live "$(cat "$LIVE_CACHE_JSON")" --arg decision "published" \
    --arg surface_fp "$SURFACE_FP" --arg underground_fp "$UNDERGROUND_FP" \
    --arg branch "$PIN_BRANCH" \
    '{
        live_cache_id: ($live.id|tonumber),
        decision: $decision,
        surface_fingerprint: $surface_fp,
        underground_fingerprint: $underground_fp,
        pin_branch: $branch,
        timestamp: (now|todateiso8601)
    }' > "$LAST_RUN"
log "map-auto-update finished"
