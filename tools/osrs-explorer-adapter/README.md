# OSRS Explorer Adapter

This prototype moves the time-sensitive capture and input loop outside Codex.
It has a native macOS host for permissions and supported public APIs, plus an
ordinary supervised Node worker for reviewed frame and queue logic.

The original full-background qualification is preserved as a sealed negative
result. The currently authorized prototype uses a bounded foreground lease:
it activates the target only for one allowlisted click or drag transaction,
then restores the prior frontmost application and, when global event delivery
is required, the prior cursor position. It waits for the target window to
return to its prior rank and fails closed if restoration does not settle. An
unexpected worker exit also faults the host. It never switches Spaces, types
text, handles credentials, or invents work outside a Steward-authorized
immutable queue.

The same operator actions are available in a compact nonactivating utility
window. The window opens on every startup and is restored on permission or
terminal runtime conditions, including `BACKGROUND_UNSUPPORTED`, independently
of `NSStatusItem.isVisible`; that property is not treated as proof that menu-bar
capacity leaves the item reachable. Each continuing condition restores the
panel once rather than reopening it on every status refresh. Enable, resume,
queue activation, queue cancellation, and job cancellation require visible
menu or panel gestures and have no command-line or environment-based path.

Foreground ownership is checked before every globally posted phase. If focus
changes after a mouse-down, the transaction emits only the matching bounded
global mouse-up needed to release the system drag, verifies through public Core
Graphics state that the button is no longer held, and then restores the prior
foreground state. An unconfirmed release is a terminal cleanup failure. No
later click or drag phase is allowed after invalidation.
Cursor restoration is covered by the same atomic permission, deadline, and
cancellation gate as CG/AX emission. Application termination synchronously
closes the active-action gate registry before sockets, requests, or the worker
are stopped, so a racing request cannot register late input work.

The packaged app has the fixed bundle identity
`com.omiyawaki.osrswiki.explorer-adapter`. It runs only from
`~/Applications/OSRS Explorer Adapter.app`; production worker, Node, bundle,
socket, and evidence paths cannot be changed through environment variables.
The mode-0700 runtime directory and process-lifetime lock live under
`~/Library/Application Support/OSRS Explorer Adapter/runtime`.

PID-directed delivery is tested first. Supported global event posting may be
tested only after active-target PID delivery fails. Virtualization, private
APIs, client injection, low-level drivers, canonical writes, and full Explorer
rollout remain excluded.

The worker pins exact `sharp@0.35.3` with
`@img/sharp-libvips-darwin-arm64@1.3.2`, and the live binding must report
`sharp.versions.vips == 8.18.3`. Sharp is outside the affected range for
`GHSA-f88m-g3jw-g9cj`. The worker still accepts only host-produced local PNG
frames and blocks the named GIF, TIFF, and VIPS loaders as defense in depth.

## Target And Capture Contract

The host binds exactly one on-screen level-zero window for the requested
application. For `com.jagex.osclient`, the primary title must be exactly
`Old School RuneScape`; hidden support windows and transient tooltip windows
are excluded, while multiple matching on-screen windows fail closed.

ScreenCaptureKit returns the native target-window pixels. Before invoking the
reviewed classifier, the worker selects exactly one tight aspect family:
768 by 839 for gameplay/map frames or 768 by 861 for ordinary recovery frames.
It normalizes only to the selected family; missing, intermediate, incompatible,
or ambiguous geometry fails closed. Every normal map-work
OSRS click or drag is authorized only after a fresh frame classifies as
`CONNECTED`, `FLOATING_MAP_OPEN`, `NONE`, and `NONBLACK_CONTENT`.
After input, the worker retains and classifies up to five fresh frames over one
second. Every rejected frame remains evidence, and the worker stops before any
later input unless one of those frames independently satisfies the same map
contract.

Ordinary button-only recovery is a separate queue semantic. An item kind of
`osrs-recovery-v1-<STATE>` must name exactly one of `TRY_AGAIN`,
`STEAM_SIGN_IN`, `CONNECTING`, `CLICK_TO_PLAY`, `GAMEPLAY_NO_MAP`, or
`CONTEXT_MENU_OPEN_MAP`. Interactive items contain exactly one capture followed
by one foreground click whose native pixel point and button match the uniquely
localized reviewed control. `CONNECTING` is capture-only. Each item proves a
fresh recognized downstream state and stops; it never invents the next item or
performs an unlisted click. Unknown, credential, account, security, stale,
ambiguous, timed-out, or context-lost states fail closed. A failed or canceled
generation is durably revoked and cannot be reactivated after restart.

`npm run readiness -- <host-produced-png>` is a read-only offline preflight. It
returns `MAP_READY`, `RECOGNIZED_RECOVERY:<STATE>`, or `PRECISELY_BLOCKED` and
never requests input, activates OSRS, or mutates adapter state.

`scripts/build-apps.sh` requires the dedicated local signing policy and emits a
post-signing `ADAPTER_BUILD_CLOSURE.json` and `SHA256SUMS` for version, source,
bundled Node, worker dependencies, certificate, designated requirement, bundle,
and command-line tool. `scripts/verify-build-closure.mjs` independently
recomputes those bindings and loads bundled Sharp to verify the live libvips
version. Construction uses the fixed Xcode 26.6 / Apple Swift 6.3.3 binaries,
the checksum-pinned official Node 26.4.0 archive, and that archive's exact
`npm@11.17.0` CLI under a sanitized build environment. Install verification
bootstraps from the same exact archive instead of accepting a current `v26.*`
binary. Live proof evidence is valid only for the exact closure installed by
`scripts/install-local.sh`.

Separate mode-0600 worker and control sockets apply a two-second absolute
request deadline to each accepted client. The worker token is memory-only and
authorizes worker methods only. The control socket validates the peer audit
token, fixed nested CLI path and identifier, certificate, and hardened runtime,
but exposes only `status` and `diagnostics`. It grants no mutating authority,
even when the signed CLI is launched or reparented by a compromised same-UID
worker. Stalled or partial clients are closed before later requests are
accepted, and shutdown explicitly closes every tracked accepted descriptor.
Concurrent second launches use immutable per-request request and acknowledgement
markers, so the primary consumes every request and each requester waits only on
its own acknowledgement.

## Prototype Queue

`node-worker/scripts/create-osrs-proof-queue.mjs` creates an immutable sandbox
queue for either capture-only qualification or the explicitly authorized
single click-and-drag proof. Its points use native ScreenCaptureKit pixel
coordinates and are bound to the fresh capture identifier before the host
accepts input. The proof script permits no keyboard input, text, credentials,
chat, movement, combat, inventory action, or canonical journal write.

The prototype proved one fresh OSRS left click and one drag with pre/post
visual evidence. It also proved immutable generation activation, duplicate
item suppression, and an authorized repair item with explicit supersession
lineage. A validated activation publishes a mode-`0444` generation-use record
before any claim or action can be returned; deadlines, cancellation, and
in-flight worker/runtime loss additionally publish a revocation record. Either
record prevents that generation identifier from being activated after restart,
while a fresh successor generation may still carry unaccepted work. These
results support only a limited-rollout review. They do not
authorize installation of an unreviewed recovery closure, a persistent Explorer
rollout, or canonical sequence advancement.

## Semantic Map Capture Queue

Queue schema version 2 adds the fixed `semantic_map_capture_v1` execution
profile while preserving raw schema version 1 unchanged. Legacy pilot semantic
items name only a reviewed surface, zoom, criterion family, and whether an
isolated test cell must restore the pre-pan position:

```json
{
  "id": "matrix-001",
  "kind": "semantic_map_capture",
  "surface": "Gielinor Surface",
  "zoom_percent": 37.5,
  "criterion_family": "eastward_topology",
  "restore_after_capture": true
}
```

Coordinates, thresholds, action counts, and input modes are not manifest
fields. The signed worker owns the reviewed surface calibration, zoom ladder,
five motion vectors, novelty thresholds, and optional inverse restoration.
The native host accepts only the finite semantic input sequence, binds every
input to its immediately preceding capture, enforces the item-specific surface
row and normalized geometry, and caps the sequence at one reviewed scrollbar
drag per selector opening, eight minus clicks, four plus clicks, one pan, and
one inverse restoration. Restoration measures the effective map displacement
between the pre-pan and fresh frames, chooses a visible map-content anchor, and
normalizes the bounded opposite vector into the current capture geometry. It
does not retry or relax the one-cell restoration gate. Visible rows bypass
selector scrolling. The terminal
realm uses exactly one bottom-thumb drag and, for isolated certification cells,
one top-thumb drag to restore Gielinor. Arrow clicks, wheel scrolling, fallback
navigation, and manifest-provided coordinates are rejected.

Scrollbar stop proof is pixel-geometric. The worker uniquely localizes the
up- and down-arrow buttons at one-pixel resolution inside the reviewed selector
region, derives the live track between them, and then localizes the 14 by 16
pixel thumb within that track. Top requires the thumb's top edge to equal the
derived track's top edge; bottom requires its bottom edge to equal the derived
track's bottom edge, both with zero-pixel tolerance. Every other position is
`intermediate`. Drag endpoints are computed from this measured geometry and
scaled into the current capture, so window-size changes do not reuse static
screen coordinates. Evidence records the button, track, thumb, normalized, and
source-frame geometry.

The worker emits semantic result schema version 2 with target identity,
surface and zoom proof, distinct pre/post/fresh frames, novelty and extent
proof, restoration proof, action input evidence, performance, map crop, and
immutable digests. `SandboxResultBroker` validates that result before adding it
to the sandbox-only acceptance chain. It never writes the canonical journal.

### Native Realm Production Planning

Native-realm production scope is exactly the reviewed live in-game selector inventory:
47 selector entries comprising Gielinor Surface plus 46 named native realms. The generated catalog is
`node-worker/src/native-realm-catalog.generated.json`, schema version 1,
catalog version `native-selector-catalog-v4`. It is regenerated by
`node-worker/scripts/generate-native-realm-catalog.mjs` from a verified
`underground-realms.json` producer manifest using the producer identities
`surface-gielinor` and `cache-world-map:*` from groups `surface` and `realms`.
The generator validates 47 accepted entries and records the exclusion proof for
Ghorrock Prison, Lassar Undercity, and Tutorial Island, which are present in the
producer manifest but absent from the reviewed live selector, plus all 1,047 `other_maps`
records. It also rejects `other-map-*`,
`cache-special-region:*`, unnamed cache records, Wiki custom views, Sailing
special maps, and Full Map special entries.

Regenerate the catalog with the implemented positional absolute-path syntax:

```sh
node node-worker/scripts/generate-native-realm-catalog.mjs \
  <absolute-underground-realms.json> \
  <absolute-renderer-provenance-root> \
  <absolute-native-realm-catalog.generated.json>
```

Production queue items are still semantic schema v2, but add catalog, planner,
realm id, selector index, capture center, and coverage-cell fields. The worker
derives scrollbar geometry from each fresh selector capture, computes either a
visible-row selection or one bounded thumb-position drag, proves the expected
label is uniquely visible, and binds every input to the immediately preceding
capture. It does not use arrow clicks, wheel scrolling, repeated drags, static
screen coordinates, or retry fallback.

Production worklists and restart ledgers are generated and verified with
machine-readable CLIs:

```sh
node node-worker/scripts/create-native-realm-production-queue.mjs \
  --generation <fresh-generation-id> \
  --artifact-root <absolute-artifact-root> \
  --queue-output <absolute-queue.json> \
  --ledger-output <absolute-ledger.json>
node node-worker/scripts/verify-native-realm-production.mjs \
  --queue <absolute-queue.json> --ledger <absolute-ledger.json>
```

The planner covers all 47 catalog entries at 37.5, 50, 75, 100, and 200
percent zoom: exactly 235 realm/zoom combinations and 617 current capture
positions. Planner v14 derives capture centers from each realm's native display
bounds and a surface-specific unobscured viewport. Gielinor Surface uses
`left=178, top=70, width=338, height=550` to exclude its fixed Key panel;
underground realms use `left=4, top=70, width=512, height=550` because they
have no Key panel. Both crops exclude the close button and lower controls.
Intermediate scrollbar pixels use the client's
floor-quantized row mapping, and broker acceptance binds the measured thumb
pixel to the exact catalog row and click box. Each realm's close/reopen center
is projected through the verified uint16 renderer-provenance owner raster into
the packed default-plane layout; it is not inferred from the display-bounds
midpoint. Catalog-v1/planner-v5 evidence
with the extra Lassar row is superseded. The locked rasters are four pixels per display unit.
When resuming within planner v14,
`create-native-realm-v11-successor.mjs` retains a prior sandbox result only
after the immutable broker chain, semantic work coordinates, result digest,
map crop, and three distinct exact-realm captures all revalidate.
`verify-native-realm-v11-successor.mjs` then proves that the retained and
pending sets partition all 617 v14 cells exactly. Geometry from earlier planner
versions is never carried into v14.
Before every item, planner v14 clicks the normalized reviewed map-close control,
requires a fresh recognized `GAMEPLAY_NO_MAP` frame, reopens the map through
the privileged world-map action, and requires fresh Gielinor readiness. It
then selects the requested realm, whose close/reopen starting center is fixed,
and applies the exact reset-center-relative pan vector. Overlap prevents
gaps, stable item ids and order make the run reproducible, and the planner
proves no center is out of
bounds. The
ledger distinguishes `planned`, `accepted_in_sandbox`, `canonically_exported`,
`failed`, `revoked`, and remaining work so restarts do not replay accepted
items or require an LLM to choose the next item. These commands prepare
sandbox-only production work; they do not install the adapter, operate OSRS, or
claim that live full capture has completed.

Pilot queues are generated rather than hand-authored:

```sh
node node-worker/scripts/create-semantic-pilot-queue.mjs matrix \
  <fresh-generation-id> <absolute-artifact-root> <absolute-output.json>
node node-worker/scripts/verify-semantic-pilot.mjs \
  --profile matrix --queue <absolute-output.json> \
  --broker-root <absolute-sandbox-broker-root> --output <absolute-report.json>
```

Supported profiles are `motion-smoke`, `surface-smoke`,
`terminal-realm-performance`, `matrix`,
`operational-soak`, `canonical-canary`, `canonical-5`, `canonical-10`, and
`canonical-25`. The matrix profile is exactly 100 unique restored combinations
covering four surfaces, five zoom levels, and five pan families. The phase
verifier requires every queued item to appear exactly once in the sandbox
acceptance chain. It validates the complete retained broker history, then
evaluates only the requested generation, so prior accepted pilots remain in
place. It enforces the 20-second no-recovery item p95, 2-second
input-to-qualified-post-capture p95, and 120-second hard item deadline. The
terminal profile additionally requires exactly 20 bottom drags, 20 Zanaris
selections, 20 restored captures, and 20 verified Gielinor resets. Its
selector-open-to-Zanaris p95 is at most 2 seconds and every cycle is at most 3
seconds.

Before any live semantic pilot, run:

```sh
node node-worker/scripts/check-semantic-calibrations.mjs
```

The gate requires reviewed Asgarnia Ice Cave and Zanaris closed-state
templates, a fresh selector capture confirming Zanaris as the terminal entry,
and reviewed Zanaris bottom-selector, thumb, track, and stop calibrations.
Every surface option and scrollbar thumb must
localize uniquely with correlation at least `0.72` and separation at least
`0.08`, and the measured thumb bounds must then equal the requested zero-tolerance
stop. A different observed terminal entry requires an explicit profile update.

Canonical export is a separate operator step. It requires both the immutable
semantic result and the matching immutable sandbox-broker acceptance commit.
Without `--execute`, it only prepares and seals an exact
`osrs-capture-broker-v4` request. With `--execute`, it uses one deterministic
idempotency key and exact-predecessor compare-and-swap; an uncertain response is
never resubmitted under another key.

The complete phase order, hold points, and replacement criteria are recorded
in `docs/internal/osrs-explorer-adapter-full-motion-pilot.md`.

## Local Release

The rollout build uses the dedicated `OSRS Explorer Adapter Local Signing`
identity and an exact certificate policy stored at
`~/Library/Application Support/OSRS Explorer Adapter/signing-policy.json`.
Creating that identity changes the login keychain and Code Signing trust, so
run `scripts/create-local-signing-identity.sh` only at the approved action-time
gate. The script creates an RSA-3072, SHA-256, ten-year self-signed certificate
whose only extended key usage is Code Signing. Its private key is imported
directly into the login keychain for `/usr/bin/codesign` and is never exported
by the adapter tooling.

After the policy exists, build and install with:

```sh
SOURCE_ROOT=/path/to/osrswiki/tools/osrs-explorer-adapter
SOURCE_COMMIT=<exact-clean-git-commit>
SIGNING_POLICY="$HOME/Library/Application Support/OSRS Explorer Adapter/signing-policy.json"
scripts/build-apps.sh "$SOURCE_ROOT" "$SOURCE_COMMIT" "$SIGNING_POLICY" /path/to/immutable-build-directory
scripts/install-local.sh /path/to/immutable-build-directory "$SOURCE_ROOT" "$SOURCE_COMMIT" "$SIGNING_POLICY"
```

The build rejects ad-hoc signing and any identity or certificate mismatch. It
embeds the checksum-pinned official Node 26.4.0 arm64 binary, exact worker
closure, exact `sharp@0.35.3` and libvips package/runtime identities, and signed
read-only control utility. Dependency reconstruction uses a fresh per-build npm
cache and never inherits the user's shared npm cache. The installer rejects a live adapter instance,
independently verifies every nested Mach-O and live Sharp binding, stages on the
destination volume, and transactionally replaces the single complete
`~/Applications/OSRS Explorer Adapter.app` unit with rollback on post-swap
verification failure.

`~/Applications/OSRS Explorer Adapter.app/Contents/MacOS/osrs-explorerctl status`
reports operational state. The read-only
`osrs-explorerctl diagnostics` adds the stable socket and lock paths, lock and
socket presence, target binding, and worker-closure check without requesting a
permission or activating OSRS. These are the CLI's only commands. All mutating
operations remain visible menu or panel gestures only. Launch-at-login intent is
persisted separately from service status, including approval-required and
opt-out states. Every launch, including login launch, starts disabled.
