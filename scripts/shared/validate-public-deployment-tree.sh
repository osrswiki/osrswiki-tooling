#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: validate-public-deployment-tree.sh <android|ios|tooling> [repo]" >&2
    exit 2
fi

platform="$1"
repository_root="${2:-.}"
case "$platform" in
    android|ios|tooling) ;;
    *)
        echo "ERROR: unsupported deployment platform: $platform" >&2
        exit 2
        ;;
esac

repository_root="$(git -C "$repository_root" rev-parse --show-toplevel)"
maximum_blob_bytes=$((10 * 1024 * 1024))
errors=0

while IFS= read -r -d '' tracked_path; do
    case "$tracked_path" in
        *.mbtiles|*.xcresult|*.apk|*.aab|*.ipa|*.dSYM|*.dSYM.zip|*.log|*.tmp)
            echo "ERROR: prohibited generated deployment path: $tracked_path" >&2
            ((++errors))
            ;;
    esac

    if [[ "$tracked_path" =~ (^|/)img-[0-9]+\.png$ ]] \
        || [[ "$tracked_path" =~ ^(cache|tools/cache)(/|$) ]] \
        || [[ "$tracked_path" =~ (^|/)(node_modules|build|output|DerivedData|qa-evidence|sessions|screenshots|recordings|test-results|captures|jagexcache|tools/bin|tools/environment|\.gradle|\.pixi|\.claude|\.codex)(/|$) ]]; then
        echo "ERROR: prohibited generated deployment path: $tracked_path" >&2
        ((++errors))
    fi

    blob_bytes="$(git -C "$repository_root" cat-file -s ":$tracked_path" 2>/dev/null || true)"
    if [[ "$blob_bytes" =~ ^[0-9]+$ ]] && (( blob_bytes > maximum_blob_bytes )); then
        echo "ERROR: tracked blob exceeds $maximum_blob_bytes bytes: $tracked_path ($blob_bytes)" >&2
        ((++errors))
    fi
done < <(git -C "$repository_root" ls-files -z)

if (( errors > 0 )); then
    echo "Public $platform deployment tree rejected with $errors error(s)." >&2
    exit 1
fi

echo "Public $platform deployment tree valid."
