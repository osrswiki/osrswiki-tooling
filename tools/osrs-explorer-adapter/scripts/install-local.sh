#!/bin/zsh -f
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset DEVELOPER_DIR TOOLCHAINS SDKROOT SWIFT_EXEC SWIFT_DRIVER_SWIFT_FRONTEND_EXEC \
  CC CXX LD AR CFLAGS CPPFLAGS CXXFLAGS LDFLAGS LIBRARY_PATH CPATH \
  NODE_OPTIONS NODE_PATH NPM_CONFIG_PREFIX NPM_CONFIG_USERCONFIG npm_config_prefix \
  npm_config_userconfig

root="${0:A:h:h}"
[[ "$#" == 4 ]] || {
  print -u2 "usage: install-local.sh BUILD_DESTINATION SOURCE_ROOT SOURCE_COMMIT SIGNING_POLICY"
  exit 64
}
build="${1:A}"
source_root="${2:A}"
source_commit="$3"
signing_policy="${4:A}"
fixed_signing_policy="$HOME/Library/Application Support/OSRS Explorer Adapter/signing-policy.json"
node_version="v26.4.0"
node_archive="$HOME/Developer/osrswiki-local-artifacts/cache/node-v26.4.0-darwin-arm64.tar.xz"
node_archive_sha256="bef4c7e75087c029835f519a7ba640eba52fa617fadb3a9049828ff3b45b57dd"
node_binary_sha256="d23e520f5bcd497bdd0c6a6242356a4fd255abaceba7c3549727caacb936ddae"
swift_tool="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
swift_tool_sha256="2ed38571e92c0283091838c1649e27650ad9c99950288e883c7b2dc6c4ce89fb"
swift_version=$'Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)\nTarget: arm64-apple-macosx26.0'
stable_root="$HOME/Applications"
stable_app="$stable_root/OSRS Explorer Adapter.app"
staging_app="$stable_root/.OSRS Explorer Adapter.install-$RANDOM-$$.app"
runtime_root="$HOME/Library/Application Support/OSRS Explorer Adapter/runtime"
runtime_lock="$runtime_root/adapter.lock"
temporary="$(/usr/bin/mktemp -d "/tmp/osrs-adapter-install.XXXXXX")"
trap '/bin/rm -rf "$staging_app" "$temporary"' EXIT

[[ -f "$node_archive" \
  && "$(/usr/bin/shasum -a 256 "$node_archive" | /usr/bin/awk '{print $1}')" == "$node_archive_sha256" ]] || {
  print -u2 "PINNED_NODE_ARCHIVE_REQUIRED"
  exit 65
}
/bin/mkdir -p "$temporary/node"
/usr/bin/tar -xJf "$node_archive" -C "$temporary/node"
tool_node="$temporary/node/node-v26.4.0-darwin-arm64/bin/node"
[[ -x "$tool_node" \
  && "$("$tool_node" --version)" == "$node_version" \
  && "$(/usr/bin/shasum -a 256 "$tool_node" | /usr/bin/awk '{print $1}')" == "$node_binary_sha256" ]] || {
  print -u2 "PINNED_NODE_TOOLCHAIN_REQUIRED"
  exit 65
}
observed_swift_version="$("$swift_tool" --version)"
observed_swift_version="${observed_swift_version#swift-driver version: 1.148.6 }"
[[ -x "$swift_tool" \
  && "$observed_swift_version" == "$swift_version" \
  && "$(/usr/bin/shasum -a 256 "$swift_tool" | /usr/bin/awk '{print $1}')" == "$swift_tool_sha256" ]] || {
  print -u2 "PINNED_SWIFT_TOOLCHAIN_REQUIRED"
  exit 65
}

[[ "$source_root" == "$root" ]] || {
  print -u2 "TRUSTED_SOURCE_ROOT_MISMATCH"
  exit 65
}
[[ "$signing_policy" == "$fixed_signing_policy" ]] || {
  print -u2 "SIGNING_POLICY_PATH_MISMATCH"
  exit 65
}

/usr/bin/env -i HOME="$HOME" TMPDIR="/tmp" PATH="$PATH" \
  "$tool_node" "$root/scripts/verify-build-closure.mjs" \
  "$build" "$source_root" "$source_commit" "$signing_policy"
/bin/mkdir -p "$stable_root"
/bin/mkdir -p "$runtime_root"
/bin/chmod 0700 "$runtime_root"
/usr/bin/ditto --noqtn "$build/OSRS Explorer Adapter.app" "$staging_app"
/usr/bin/env -i HOME="$HOME" TMPDIR="/tmp" PATH="$PATH" \
  "$tool_node" "$root/scripts/verify-installed-bundle.mjs" \
  "$build" "$staging_app" "$source_root" "$source_commit" "$signing_policy"
/usr/bin/env -i HOME="$HOME" TMPDIR="/tmp" PATH="$PATH" \
  "$swift_tool" "$root/scripts/install-transaction.swift" \
  "$staging_app" "$stable_app" "$runtime_lock" \
  "$root/scripts/verify-installed-bundle.mjs" \
  "$tool_node" "$build" "$source_root" "$source_commit" "$signing_policy"

printf '%s\n' "$stable_app"
