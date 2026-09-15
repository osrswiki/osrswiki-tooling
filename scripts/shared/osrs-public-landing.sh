#!/usr/bin/env bash
# Install rendered public-landing README (and optional LICENSE/assets) into a dest tree.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  osrs-public-landing.sh install \
    --target android|ios|tooling|privacy-policy|org \
    --dest <staging-dir> \
    --landing-root <fleet>/docs/public-landing
USAGE
}

die() {
  echo "osrs-public-landing: error: $*" >&2
  exit 1
}

cmd="${1:-}"
if [[ -z "$cmd" ]]; then
  usage >&2
  exit 2
fi
shift

case "$cmd" in
  install) ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    die "unknown command: $cmd (expected install)"
    ;;
esac

TARGET=""
DEST=""
LANDING_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || die "--target requires a value"
      TARGET="$2"
      shift 2
      ;;
    --dest)
      [[ $# -ge 2 ]] || die "--dest requires a value"
      DEST="$2"
      shift 2
      ;;
    --landing-root)
      [[ $# -ge 2 ]] || die "--landing-root requires a value"
      LANDING_ROOT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$TARGET" ]] || die "--target is required"
[[ -n "$DEST" ]] || die "--dest is required"
[[ -n "$LANDING_ROOT" ]] || die "--landing-root is required"

case "$TARGET" in
  android|ios|tooling|privacy-policy|org) ;;
  *) die "invalid --target: $TARGET (expected android|ios|tooling|privacy-policy|org)" ;;
esac

LANDING_ROOT="$(cd "$LANDING_ROOT" && pwd)"
MANIFEST="$LANDING_ROOT/manifest.yaml"
[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"

TEMPLATE_NAME="README.${TARGET}.md"
TEMPLATE="$LANDING_ROOT/$TEMPLATE_NAME"
[[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE"

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

# Render README via python3 (YAML + placeholders + SPONSORS blocks).
# Prefer PyYAML when present; otherwise parse this project's flat manifest.
RENDERED="$(
python3 - "$MANIFEST" "$TEMPLATE" "$TARGET" <<'PY'
import re
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
template_path = Path(sys.argv[2])
target = sys.argv[3]

def load_manifest(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    try:
        import yaml  # type: ignore
        data = yaml.safe_load(text)
        if not isinstance(data, dict):
            raise SystemExit(f"manifest root must be a mapping: {path}")
        # Normalize None -> "" for empty YAML nulls
        return {str(k): ("" if v is None else str(v)) for k, v in data.items()}
    except ImportError:
        pass

    # Tiny flat YAML subset: key: value  (optional trailing # comment)
    out = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            continue
        key, rest = line.split(":", 1)
        key = key.strip()
        rest = rest.strip()
        # Strip unquoted trailing comments (preserve # inside quoted strings)
        if rest.startswith('"'):
            # "..." optional comment
            m = re.match(r'^"(.*)"\s*(?:#.*)?$', rest)
            if not m:
                raise SystemExit(f"unclosed quoted value for {key} in {path}")
            value = m.group(1)
        elif rest.startswith("'"):
            m = re.match(r"^'(.*)'\s*(?:#.*)?$", rest)
            if not m:
                raise SystemExit(f"unclosed quoted value for {key} in {path}")
            value = m.group(1)
        else:
            # Strip trailing comment if present (space+#). Keep bare values.
            if " #" in rest:
                rest = rest.split(" #", 1)[0].rstrip()
            elif rest.startswith("#"):
                rest = ""
            value = rest
        out[key] = value
    return out

def resolve_sponsors(body: str, status: str) -> str:
    status = (status or "").strip().lower()
    if status not in ("live", "pending"):
        raise SystemExit(
            f"sponsors_status must be 'live' or 'pending' (got {status!r})"
        )

    def unwrap(kind: str, text: str, keep: bool) -> str:
        # <!-- SPONSORS_KIND\n...\nSPONSORS_KIND -->
        pattern = re.compile(
            rf"<!--\s*SPONSORS_{kind}\s*\n(.*?)\nSPONSORS_{kind}\s*-->",
            re.DOTALL,
        )
        if keep:
            return pattern.sub(lambda m: m.group(1).rstrip("\n"), text)
        return pattern.sub("", text)

    if status == "live":
        body = unwrap("LIVE", body, keep=True)
        body = unwrap("PENDING", body, keep=False)
    else:
        body = unwrap("PENDING", body, keep=True)
        body = unwrap("LIVE", body, keep=False)

    # Collapse accidental triple blank lines left by removed blocks
    body = re.sub(r"\n{3,}", "\n\n", body)
    return body

def substitute(body: str, values: dict) -> str:
    def repl(m: re.Match) -> str:
        key = m.group(1)
        if key not in values:
            # Leave unknown keys untouched so callers can detect leftovers.
            return m.group(0)
        return values[key]

    return re.sub(r"\{\{([A-Za-z0-9_]+)\}\}", repl, body)

manifest = load_manifest(manifest_path)
template = template_path.read_text(encoding="utf-8")
rendered = resolve_sponsors(template, manifest.get("sponsors_status", ""))
rendered = substitute(rendered, manifest)

# Guard: no placeholder may survive rendering. Android and iOS cross-link each
# other's store URL and source repo, so a key missing from the manifest would
# otherwise leak a raw {{key}} into a published README.
leftover = sorted(set(re.findall(r"\{\{([A-Za-z0-9_]+)\}\}", rendered)))
if leftover:
    raise SystemExit(
        f"{target} README still contains unresolved placeholders: "
        + ", ".join("{{" + k + "}}" for k in leftover)
    )

# Guard: a key present but empty renders as a link with no target. Fail closed
# rather than publish a dead Install or cross-platform CTA.
if re.search(r"\]\(\s*\)", rendered):
    raise SystemExit(
        f"{target} README contains a link with an empty target; "
        "check that every URL referenced by the template is set in the manifest"
    )

sys.stdout.write(rendered)
if not rendered.endswith("\n"):
    sys.stdout.write("\n")
PY
)" || die "failed to render README for target=$TARGET"

printf '%s' "$RENDERED" > "$DEST/README.md"

# LICENSE for product/tooling trees only (not privacy-policy or org).
case "$TARGET" in
  android|ios|tooling)
    LICENSE_SRC="$LANDING_ROOT/LICENSE.GPL-3.0-or-later.txt"
    [[ -f "$LICENSE_SRC" ]] || die "license text not found: $LICENSE_SRC"
    cp "$LICENSE_SRC" "$DEST/LICENSE"
    ;;
esac

# Assets: copy screenshot files when the manifest enables them. iOS still copies
# marketing badges (App Store CTA) when screenshots is none. Skip when the
# source assets directory is absent/empty.
SCREENSHOTS="$(
python3 - "$MANIFEST" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
try:
    import yaml  # type: ignore
    data = yaml.safe_load(text) or {}
    print((data.get("screenshots") or "").strip())
    raise SystemExit(0)
except ImportError:
    pass
for raw in text.splitlines():
    line = raw.strip()
    if line.startswith("screenshots:"):
        rest = line.split(":", 1)[1].strip()
        if " #" in rest:
            rest = rest.split(" #", 1)[0].rstrip()
        if rest.startswith('"') and rest.endswith('"'):
            rest = rest[1:-1]
        print(rest)
        raise SystemExit(0)
print("")
PY
)"

SCREENSHOTS_LC="$(printf '%s' "$SCREENSHOTS" | tr '[:upper:]' '[:lower:]')"
copy_assets="yes"
case "$SCREENSHOTS_LC" in
  ""|none|false|no|null|~)
    copy_assets="no"
    ;;
esac

ASSETS_SRC="$LANDING_ROOT/assets"
# iOS marketing badges (App Store CTA) are copied even when screenshots: none.
# Android still waits on the screenshot waiver.
should_copy_assets="no"
case "$TARGET" in
  ios)
    should_copy_assets="yes"
    ;;
  android)
    should_copy_assets="$copy_assets"
    ;;
esac
if [[ "$should_copy_assets" == "yes" && -d "$ASSETS_SRC" ]]; then
  if compgen -G "$ASSETS_SRC/*" > /dev/null; then
    mkdir -p "$DEST/assets"
    # Copy files (not nested dirs unless present); keep flat assets layout.
    cp -R "$ASSETS_SRC/." "$DEST/assets/"
  fi
fi

echo "osrs-public-landing: installed $TARGET -> $DEST/README.md"
