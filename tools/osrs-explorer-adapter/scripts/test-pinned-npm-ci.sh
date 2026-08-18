#!/bin/zsh -f
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
unset NODE_OPTIONS NODE_PATH NPM_CONFIG_PREFIX NPM_CONFIG_USERCONFIG npm_config_prefix \
  npm_config_userconfig

root="${0:A:h:h}"
build_script="$root/scripts/build-apps.sh"
node_version="v26.4.0"
node_archive_name="node-v26.4.0-darwin-arm64.tar.xz"
node_archive_sha256="bef4c7e75087c029835f519a7ba640eba52fa617fadb3a9049828ff3b45b57dd"
node_binary_sha256="d23e520f5bcd497bdd0c6a6242356a4fd255abaceba7c3549727caacb936ddae"
npm_version="11.17.0"
npm_cli_sha256="8e5f6f3429f8cdbe693cdc29904e9d5a7b127a494bd15c804bd54c7403bfcbe7"
node_archive="$HOME/Developer/osrswiki-local-artifacts/cache/$node_archive_name"

if /usr/bin/grep -Fq -- '--prefix' "$build_script"; then
  print -u2 "BUILD_NPM_PREFIX_FORBIDDEN"
  exit 1
fi
/usr/bin/grep -Fq 'cd "$root/node-worker"' "$build_script" || {
  print -u2 "BUILD_NPM_WORKING_DIRECTORY_REQUIRED"
  exit 1
}

[[ -f "$node_archive" ]] || {
  print -u2 "NODE_ARCHIVE_REQUIRED:$node_archive"
  exit 1
}
[[ "$(/usr/bin/shasum -a 256 "$node_archive" | /usr/bin/awk '{print $1}')" == "$node_archive_sha256" ]] || {
  print -u2 "NODE_ARCHIVE_SHA256_MISMATCH"
  exit 1
}

temporary="$(/usr/bin/mktemp -d "/tmp/osrs-adapter-npm-ci-test.XXXXXX")"
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

worker_copy="$temporary/node-worker"
/usr/bin/ditto --noqtn "$root/node-worker" "$worker_copy"
/bin/rm -rf "$worker_copy/node_modules"
/usr/bin/cmp -s "$root/node-worker/package-lock.json" "$worker_copy/package-lock.json" || {
  print -u2 "CLEAN_COPY_PACKAGE_LOCK_MISMATCH"
  exit 1
}
lock_before="$(/usr/bin/shasum -a 256 "$worker_copy/package-lock.json" | /usr/bin/awk '{print $1}')"
npm_cache="$temporary/npm-cache"
[[ ! -e "$npm_cache" ]] || {
  print -u2 "NPM_CACHE_NOT_FRESH"
  exit 1
}

(
  cd "$worker_copy"
  /usr/bin/env -i HOME="$HOME" TMPDIR="/tmp" PATH="$PATH" \
    "$tool_node" "$tool_npm_cli" \
    --cache "$npm_cache" \
    ci --omit=dev
)

[[ -d "$npm_cache" ]] || {
  print -u2 "ISOLATED_NPM_CACHE_MISSING"
  exit 1
}
lock_after="$(/usr/bin/shasum -a 256 "$worker_copy/package-lock.json" | /usr/bin/awk '{print $1}')"
[[ "$lock_after" == "$lock_before" ]] || {
  print -u2 "PACKAGE_LOCK_MUTATED"
  exit 1
}
/usr/bin/cmp -s "$root/node-worker/package-lock.json" "$worker_copy/package-lock.json" || {
  print -u2 "PACKAGE_LOCK_BYTES_CHANGED"
  exit 1
}
[[ "$("$tool_node" -p 'require(process.argv[1]).version' "$worker_copy/node_modules/sharp/package.json")" == "0.35.3" ]] || {
  print -u2 "SHARP_VERSION_MISMATCH"
  exit 1
}
[[ "$("$tool_node" -e 'const sharp=require(process.argv[1]);process.stdout.write(sharp.versions.vips)' "$worker_copy/node_modules/sharp")" == "8.18.3" ]] || {
  print -u2 "LIVE_LIBVIPS_VERSION_MISMATCH"
  exit 1
}

print "PINNED_NPM_CI_WORKDIR_REGRESSION_PASS"
