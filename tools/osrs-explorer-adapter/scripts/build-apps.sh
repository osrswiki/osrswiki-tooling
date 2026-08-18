#!/bin/zsh -f
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset DEVELOPER_DIR TOOLCHAINS SDKROOT SWIFT_EXEC SWIFT_DRIVER_SWIFT_FRONTEND_EXEC \
  CC CXX LD AR CFLAGS CPPFLAGS CXXFLAGS LDFLAGS LIBRARY_PATH CPATH \
  NODE_OPTIONS NODE_PATH NPM_CONFIG_PREFIX NPM_CONFIG_USERCONFIG npm_config_prefix \
  npm_config_userconfig

root="${0:A:h:h}"
[[ "$#" == 4 ]] || {
  print -u2 "usage: build-apps.sh SOURCE_ROOT SOURCE_COMMIT SIGNING_POLICY DESTINATION"
  exit 64
}
trusted_source_root="${1:A}"
trusted_source_commit="$2"
signing_policy="${3:A}"
destination="${4:A}"
bundle_id="com.omiyawaki.osrswiki.explorer-adapter"
cli_id="com.omiyawaki.osrswiki.explorer-adapter.cli"
release_version="0.2.0"
node_version="v26.4.0"
node_archive_name="node-v26.4.0-darwin-arm64.tar.xz"
node_archive_sha256="bef4c7e75087c029835f519a7ba640eba52fa617fadb3a9049828ff3b45b57dd"
node_binary_sha256="d23e520f5bcd497bdd0c6a6242356a4fd255abaceba7c3549727caacb936ddae"
npm_version="11.17.0"
npm_cli_sha256="8e5f6f3429f8cdbe693cdc29904e9d5a7b127a494bd15c804bd54c7403bfcbe7"
node_archive="$HOME/Developer/osrswiki-local-artifacts/cache/$node_archive_name"
fixed_signing_policy="$HOME/Library/Application Support/OSRS Explorer Adapter/signing-policy.json"
node_entitlements="$root/Resources/NodeRuntime.entitlements"
swift_tool="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
swiftc_tool="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
xcodebuild_tool="/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
swift_tool_sha256="2ed38571e92c0283091838c1649e27650ad9c99950288e883c7b2dc6c4ce89fb"
xcodebuild_tool_sha256="d508f0e1901151843804e4af512d4587ad0e422039e43e14abf22792360ad3d4"
swift_version=$'Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)\nTarget: arm64-apple-macosx26.0'
xcode_version=$'Xcode 26.6\nBuild version 17F113'

[[ "$trusted_source_root" == "$root" ]] || {
  print -u2 "TRUSTED_SOURCE_ROOT_MISMATCH"
  exit 1
}
[[ "$signing_policy" == "${fixed_signing_policy:A}" ]] || {
  print -u2 "SIGNING_POLICY_PATH_MISMATCH"
  exit 1
}
[[ "$trusted_source_commit" =~ '^[0-9a-f]{40}$' ]] || {
  print -u2 "TRUSTED_SOURCE_COMMIT_INVALID"
  exit 1
}
[[ -x "$swift_tool" && -x "$swiftc_tool" && -x "$xcodebuild_tool" ]] || {
  print -u2 "PINNED_APPLE_TOOLCHAIN_REQUIRED"
  exit 1
}
[[ "$(/usr/bin/shasum -a 256 "$swift_tool" | /usr/bin/awk '{print $1}')" == "$swift_tool_sha256" \
  && "$(/usr/bin/shasum -a 256 "$swiftc_tool" | /usr/bin/awk '{print $1}')" == "$swift_tool_sha256" \
  && "$(/usr/bin/shasum -a 256 "$xcodebuild_tool" | /usr/bin/awk '{print $1}')" == "$xcodebuild_tool_sha256" ]] || {
  print -u2 "PINNED_APPLE_TOOLCHAIN_DIGEST_MISMATCH"
  exit 1
}
observed_swift_version="$("$swift_tool" --version)"
observed_swift_version="${observed_swift_version#swift-driver version: 1.148.6 }"
[[ "$observed_swift_version" == "$swift_version" \
  && "$("$xcodebuild_tool" -version)" == "$xcode_version" ]] || {
  print -u2 "PINNED_APPLE_TOOLCHAIN_VERSION_MISMATCH"
  exit 1
}
[[ "$(/usr/bin/git -C "$root" rev-parse HEAD)" == "$trusted_source_commit" ]] || {
  print -u2 "TRUSTED_SOURCE_COMMIT_MISMATCH"
  exit 1
}
[[ -z "$(/usr/bin/git -C "$root" status --porcelain=v1 -- "$root")" ]] || {
  print -u2 "SOURCE_NOT_CLEAN"
  exit 1
}

[[ -f "$signing_policy" ]] || {
  print -u2 "SIGNING_POLICY_REQUIRED:$signing_policy"
  exit 1
}
signing_identity="$(/usr/bin/plutil -extract identity raw "$signing_policy")"
certificate_sha256="$(/usr/bin/plutil -extract certificate_sha256 raw "$signing_policy" | /usr/bin/tr '[:lower:]' '[:upper:]')"
certificate_sha1="$(/usr/bin/plutil -extract certificate_sha1 raw "$signing_policy" | /usr/bin/tr '[:lower:]' '[:upper:]')"
[[ "$signing_identity" == "OSRS Explorer Adapter Local Signing" ]] || {
  print -u2 "SIGNING_IDENTITY_NAME_MISMATCH"
  exit 1
}
[[ "$certificate_sha256" =~ '^[0-9A-F]{64}$' ]] || {
  print -u2 "SIGNING_CERTIFICATE_SHA256_INVALID"
  exit 1
}
[[ "$certificate_sha1" =~ '^[0-9A-F]{40}$' ]] || {
  print -u2 "SIGNING_CERTIFICATE_SHA1_INVALID"
  exit 1
}

certificate_pem="$(/usr/bin/security find-certificate -c "$signing_identity" -p "$HOME/Library/Keychains/login.keychain-db")"
observed_sha256="$(print -r -- "$certificate_pem" | /opt/homebrew/bin/openssl x509 -noout -fingerprint -sha256 | /usr/bin/cut -d= -f2 | /usr/bin/tr -d ':' | /usr/bin/tr '[:lower:]' '[:upper:]')"
observed_sha1="$(print -r -- "$certificate_pem" | /opt/homebrew/bin/openssl x509 -noout -fingerprint -sha1 | /usr/bin/cut -d= -f2 | /usr/bin/tr -d ':' | /usr/bin/tr '[:lower:]' '[:upper:]')"
[[ "$observed_sha256" == "$certificate_sha256" && "$observed_sha1" == "$certificate_sha1" ]] || {
  print -u2 "SIGNING_CERTIFICATE_FINGERPRINT_MISMATCH"
  exit 1
}

[[ -f "$node_archive" ]] || {
  print -u2 "NODE_ARCHIVE_REQUIRED:$node_archive"
  exit 1
}
observed_node_archive_sha256="$(/usr/bin/shasum -a 256 "$node_archive" | /usr/bin/awk '{print $1}')"
[[ "$observed_node_archive_sha256" == "$node_archive_sha256" ]] || {
  print -u2 "NODE_ARCHIVE_SHA256_MISMATCH"
  exit 1
}

temporary="$(/usr/bin/mktemp -d "/tmp/osrs-adapter-build.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT
/bin/mkdir -p "$temporary/node"
/usr/bin/tar -xJf "$node_archive" -C "$temporary/node"
tool_node="$temporary/node/node-v26.4.0-darwin-arm64/bin/node"
tool_npm_cli="$temporary/node/node-v26.4.0-darwin-arm64/lib/node_modules/npm/bin/npm-cli.js"
tool_npm_package="$temporary/node/node-v26.4.0-darwin-arm64/lib/node_modules/npm/package.json"
[[ -x "$tool_node" && -f "$tool_npm_cli" && -f "$tool_npm_package" ]] || {
  print -u2 "PINNED_NODE_TOOLCHAIN_REQUIRED"
  exit 1
}
[[ "$("$tool_node" --version)" == "$node_version" \
  && "$(/usr/bin/shasum -a 256 "$tool_node" | /usr/bin/awk '{print $1}')" == "$node_binary_sha256" ]] || {
  print -u2 "PINNED_NODE_TOOLCHAIN_IDENTITY_MISMATCH"
  exit 1
}
[[ "$("$tool_node" -p 'require(process.argv[1]).version' "$tool_npm_package")" == "$npm_version" \
  && "$(/usr/bin/shasum -a 256 "$tool_npm_cli" | /usr/bin/awk '{print $1}')" == "$npm_cli_sha256" ]] || {
  print -u2 "PINNED_NPM_CLI_IDENTITY_MISMATCH"
  exit 1
}

(
  cd "$root/node-worker"
  /usr/bin/env -i HOME="$HOME" TMPDIR="/tmp" PATH="$PATH" \
    "$tool_node" "$tool_npm_cli" \
    --cache "$temporary/npm-cache" \
    ci --omit=dev
)
[[ "$("$tool_node" -p 'require(process.argv[1]).version' "$root/node-worker/node_modules/sharp/package.json")" == "0.35.3" ]] || {
  print -u2 "SHARP_VERSION_MISMATCH"
  exit 1
}
[[ "$("$tool_node" -e 'const p=require(process.argv[1]);process.stdout.write(`${p.name}@${p.version}`)' "$root/node-worker/node_modules/@img/sharp-libvips-darwin-arm64/package.json")" == "@img/sharp-libvips-darwin-arm64@1.3.2" ]] || {
  print -u2 "LIBVIPS_PACKAGE_IDENTITY_MISMATCH"
  exit 1
}
[[ "$("$tool_node" -e 'const sharp=require(process.argv[1]);process.stdout.write(sharp.versions.vips)' "$root/node-worker/node_modules/sharp")" == "8.18.3" ]] || {
  print -u2 "LIVE_LIBVIPS_VERSION_MISMATCH"
  exit 1
}
/usr/bin/env -i HOME="$HOME" TMPDIR="/tmp" PATH="$PATH" \
  "$swift_tool" build --package-path "$root" --scratch-path "$temporary/swift-build" -c release

source_commit="$(/usr/bin/git -C "$root" rev-parse HEAD)"
build_number="$(/usr/bin/git -C "$root" rev-list --count HEAD)"
requirement_file="$temporary/designated-requirement.txt"

set_plist() {
  local plist="$1"
  local key="$2"
  local value="$3"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist"
}

make_app() {
  local name="$1"
  local executable="$2"
  local plist_source="$3"
  local app="$destination/$name.app"
  /bin/rm -rf "$app"
  /bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  /bin/cp "$temporary/swift-build/release/$executable" "$app/Contents/MacOS/$executable"
  /bin/cp "$root/Resources/$plist_source" "$app/Contents/Info.plist"
}

sign_bundle() {
  local app="$1"
  local identifier
  identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
  /usr/bin/printf 'designated => identifier "%s" and certificate leaf = H"%s"\n' \
    "$identifier" "$certificate_sha1" > "$requirement_file"
  /usr/bin/codesign --force --options runtime --timestamp=none \
    --requirements "$requirement_file" --sign "$signing_identity" "$app"
  /usr/bin/codesign --verify --strict --deep --verbose=2 "$app"
}

/bin/mkdir -p "$destination"
make_app "OSRS Explorer Adapter" "osrs-explorer-adapter" "ExplorerAdapter-Info.plist"
make_app "Explorer Adapter Lab Target" "osrs-explorer-lab-target" "LabTarget-Info.plist"
make_app "Explorer Adapter Lab Cover" "osrs-explorer-lab-target" "LabCover-Info.plist"

adapter="$destination/OSRS Explorer Adapter.app"
set_plist "$adapter/Contents/Info.plist" CFBundleIdentifier "$bundle_id"
set_plist "$adapter/Contents/Info.plist" CFBundleShortVersionString "$release_version"
set_plist "$adapter/Contents/Info.plist" CFBundleVersion "$build_number"
set_plist "$adapter/Contents/Info.plist" OSRSAdapterSourceCommit "$source_commit"
set_plist "$adapter/Contents/Info.plist" OSRSAdapterSigningCertificateSHA256 "$certificate_sha256"
set_plist "$adapter/Contents/Info.plist" OSRSAdapterSigningCertificateSHA1 "$certificate_sha1"

/bin/cp "$temporary/swift-build/release/osrs-explorerctl" \
  "$adapter/Contents/MacOS/osrs-explorerctl"
/bin/chmod 0755 "$adapter/Contents/MacOS/osrs-explorerctl"

/usr/bin/ditto --noqtn "$root/node-worker" "$adapter/Contents/Resources/node-worker"
/bin/rm -rf "$adapter/Contents/Resources/node-worker/node_modules/.cache"
/bin/rm -rf "$adapter/Contents/Resources/node-worker/node_modules/.bin"

/bin/mkdir -p "$adapter/Contents/Resources/node/bin"
/bin/cp "$temporary/node/node-v26.4.0-darwin-arm64/bin/node" \
  "$adapter/Contents/Resources/node/bin/node"
/bin/chmod 0755 "$adapter/Contents/Resources/node/bin/node"
[[ "$("$adapter/Contents/Resources/node/bin/node" --version)" == "$node_version" ]] || {
  print -u2 "BUNDLED_NODE_VERSION_MISMATCH"
  exit 1
}

while IFS= read -r -d '' candidate; do
  if /usr/bin/file "$candidate" | /usr/bin/grep -q 'Mach-O'; then
    [[ "$candidate" == "$adapter/Contents/MacOS/osrs-explorer-adapter" ]] && continue
    relative="${candidate#$adapter/}"
    if [[ "$relative" == "Contents/MacOS/osrs-explorerctl" ]]; then
      identifier="$cli_id"
    else
      suffix="$(/usr/bin/printf '%s' "$relative" | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-20)"
      identifier="$bundle_id.nested.$suffix"
    fi
    /usr/bin/printf 'designated => identifier "%s" and certificate leaf = H"%s"\n' \
      "$identifier" "$certificate_sha1" > "$requirement_file"
    typeset -a signing_arguments
    signing_arguments=(
      --sign "$signing_identity"
      --force --options runtime --timestamp=none
      --identifier "$identifier" --requirements "$requirement_file"
    )
    if [[ "$candidate" == "$adapter/Contents/Resources/node/bin/node" ]]; then
      signing_arguments+=(--generate-entitlement-der --entitlements "$node_entitlements")
    fi
    /usr/bin/codesign "${signing_arguments[@]}" "$candidate"
  fi
done < <(/usr/bin/find "$adapter/Contents/Resources" -type f -print0)

/usr/bin/printf 'designated => identifier "%s" and certificate leaf = H"%s"\n' \
  "$cli_id" "$certificate_sha1" > "$requirement_file"
/usr/bin/codesign --force --options runtime --timestamp=none \
  --identifier "$cli_id" --requirements "$requirement_file" \
  --sign "$signing_identity" "$adapter/Contents/MacOS/osrs-explorerctl"

/usr/bin/env -i HOME="$HOME" TMPDIR="/tmp" PATH="$PATH" \
  "$tool_node" "$root/scripts/write-worker-runtime-closure.mjs" \
  "$adapter/Contents/Resources/node-worker" \
  "$adapter/Contents/Resources/WORKER_RUNTIME_CLOSURE.json"

for lab in "$destination/Explorer Adapter Lab Target.app" "$destination/Explorer Adapter Lab Cover.app"; do
  sign_bundle "$lab"
done
sign_bundle "$adapter"

/usr/bin/env -i HOME="$HOME" TMPDIR="/tmp" PATH="$PATH" \
  "$tool_node" "$root/scripts/write-build-closure.mjs" \
  "$trusted_source_root" "$trusted_source_commit" "$destination" \
  "$signing_policy" "$node_archive_sha256" "$tool_npm_cli"
/usr/bin/env -i HOME="$HOME" TMPDIR="/tmp" PATH="$PATH" \
  "$tool_node" "$root/scripts/verify-build-closure.mjs" \
  "$destination" "$trusted_source_root" "$trusted_source_commit" "$signing_policy"

printf '%s\n' "$destination"
