#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import {
  PINNED_RELEASE_TOOLCHAIN,
  combinedProcessOutput,
  expectedEntitlementsForPath,
  readEffectiveEntitlements,
  validateTrustedReleaseManifest
} from "./release-verification.mjs";
import {
  createCandidateExecutionGuard,
  verifyBuildChecksums,
  verifyStaticRuntimeClosure
} from "./static-build-verification.mjs";

const rawArguments = process.argv.slice(2);
const staticOnly = rawArguments[0] === "--static-only";
const arguments_ = staticOnly ? rawArguments.slice(1) : rawArguments;
const [destinationArgument, sourceRootArgument, sourceCommit, signingPolicyArgument, ...unexpectedArguments] = arguments_;
if (!destinationArgument || !sourceRootArgument || !sourceCommit || !signingPolicyArgument || unexpectedArguments.length > 0) {
  throw new Error("usage: verify-build-closure.mjs [--static-only] <build-destination> <source-root> <source-commit> <signing-policy>");
}

const destination = fs.realpathSync(destinationArgument);
const commandRunner = createCandidateExecutionGuard({ candidateRoot: destination, staticOnly });
const sourceRoot = fs.realpathSync(sourceRootArgument);
const signingPolicyPath = fs.realpathSync(signingPolicyArgument);
const signingPolicy = JSON.parse(fs.readFileSync(signingPolicyPath, "utf8"));
const manifestPath = path.join(destination, "ADAPTER_BUILD_CLOSURE.json");
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
validateTrustedReleaseManifest(manifest, {
  sourceRoot,
  sourceCommit,
  signingPolicyPath,
  certificateSHA256: signingPolicy.certificate_sha256,
  certificateSHA1: signingPolicy.certificate_sha1
});
assertValue(command("/usr/bin/git", ["-C", sourceRoot, "rev-parse", "HEAD"]), sourceCommit, "SOURCE_HEAD_MISMATCH");
assertValue(command("/usr/bin/git", ["-C", sourceRoot, "status", "--porcelain=v1", "--", sourceRoot]), "", "SOURCE_NOT_CLEAN");

const sourceFiles = describeTree(sourceRoot, new Set([".build", "node_modules"]));
const appPath = path.join(destination, "OSRS Explorer Adapter.app");
const bundleFiles = describeTree(appPath);
assertEqual(sourceFiles, manifest.source.files, "SOURCE_FILE_CLOSURE_MISMATCH");
assertEqual(bundleFiles, manifest.adapter_bundle.files, "BUNDLE_FILE_CLOSURE_MISMATCH");
assertValue(closureDigest(sourceFiles), manifest.source.closure_sha256, "SOURCE_CLOSURE_DIGEST_MISMATCH");
assertValue(closureDigest(bundleFiles), manifest.adapter_bundle.closure_sha256, "BUNDLE_CLOSURE_DIGEST_MISMATCH");

const ctlPath = path.join(appPath, "Contents", "MacOS", "osrs-explorerctl");
const ctl = signatureRecord(ctlPath, appPath);
assertEqual(ctl, manifest.control_utility, "CONTROL_UTILITY_MISMATCH");
command("/usr/bin/codesign", ["--verify", "--strict", "--deep", "--verbose=2", appPath], true);
const signature = commandCombined("/usr/bin/codesign", ["-d", "-r-", "--verbose=4", appPath]);
assertValue(matchRequired(signature, /^CDHash=(.+)$/m, "CDHash"), manifest.adapter_bundle.cdhash, "CDHASH_MISMATCH");
const bundleIdentifier = command("/usr/libexec/PlistBuddy", [
  "-c",
  "Print :CFBundleIdentifier",
  path.join(appPath, "Contents", "Info.plist")
]);
assertValue(bundleIdentifier, manifest.adapter_bundle.bundle_identifier, "BUNDLE_IDENTIFIER_MISMATCH");
const bundleDesignatedRequirement = assertSigningCertificateBinding(
  signature,
  bundleIdentifier,
  signingPolicy.certificate_sha1
);
assertValue(bundleDesignatedRequirement, manifest.adapter_bundle.designated_requirement, "DESIGNATED_REQUIREMENT_MISMATCH");
assertEqual(readEffectiveEntitlements(appPath, {}), manifest.adapter_bundle.entitlements, "BUNDLE_ENTITLEMENTS_MISMATCH");
for (const [key, manifestKey] of [
  ["CFBundleShortVersionString", "version"],
  ["CFBundleVersion", "build_number"],
  ["OSRSAdapterSourceCommit", "source_commit"],
  ["OSRSAdapterSigningCertificateSHA256", "signing_certificate_sha256"]
]) {
  const value = command("/usr/libexec/PlistBuddy", ["-c", `Print :${key}`, path.join(appPath, "Contents", "Info.plist")]);
  assertValue(value.toUpperCase(), String(manifest.adapter_bundle[manifestKey]).toUpperCase(), `PLIST_${key}_MISMATCH`);
}
if (!manifest.adapter_bundle.hardened_runtime || !/flags=.*runtime/m.test(signature)) {
  throw new Error("HARDENED_RUNTIME_REQUIRED");
}
const observedMachO = bundleFiles
  .map((file) => path.join(appPath, file.path))
  .filter(isMachO)
  .map((file) => signatureRecord(file, appPath));
assertEqual(observedMachO, manifest.mach_o, "MACH_O_CLOSURE_MISMATCH");

const nodePath = path.join(appPath, manifest.node_runtime.path);
assertEqual(describeFile(nodePath, appPath), {
  path: manifest.node_runtime.path,
  sha256: manifest.node_runtime.sha256,
  size: manifest.node_runtime.size,
  mode: manifest.node_runtime.mode
}, "BUNDLED_NODE_MISMATCH");
let dependencyIdentity;
if (staticOnly) {
  dependencyIdentity = verifyStaticRuntimeClosure({ appPath, manifest, bundleFiles });
} else {
  assertValue(command(nodePath, ["--version"]), manifest.node_runtime.version, "BUNDLED_NODE_VERSION_MISMATCH");
  const sharpPackagePath = path.join(appPath, manifest.worker_dependencies.sharp.package.path);
  const sharpPackage = JSON.parse(fs.readFileSync(sharpPackagePath, "utf8"));
  assertValue(sharpPackage.name, "sharp", "SHARP_PACKAGE_NAME_MISMATCH");
  assertValue(sharpPackage.version, PINNED_RELEASE_TOOLCHAIN.sharp.version, "SHARP_VERSION_MISMATCH");
  const sharpPackageCount = bundleFiles.filter((file) => file.path.endsWith("node_modules/sharp/package.json")).length;
  assertValue(sharpPackageCount, 1, "SHARP_PACKAGE_COUNT_INVALID");
  const libvipsPackagePath = path.join(appPath, manifest.worker_dependencies.libvips.package.path);
  const libvipsPackage = JSON.parse(fs.readFileSync(libvipsPackagePath, "utf8"));
  assertValue(libvipsPackage.name, PINNED_RELEASE_TOOLCHAIN.libvips.package_name, "LIBVIPS_PACKAGE_NAME_MISMATCH");
  assertValue(libvipsPackage.version, PINNED_RELEASE_TOOLCHAIN.libvips.package_version, "LIBVIPS_PACKAGE_VERSION_MISMATCH");
  const libvipsPackageCount = bundleFiles.filter(
    (file) => file.path.endsWith("node_modules/@img/sharp-libvips-darwin-arm64/package.json")
  ).length;
  assertValue(libvipsPackageCount, 1, "LIBVIPS_PACKAGE_COUNT_INVALID");
  const liveSharpVersions = JSON.parse(command(nodePath, [
    "-e",
    `const sharp=require(${JSON.stringify(path.dirname(sharpPackagePath))});process.stdout.write(JSON.stringify(sharp.versions))`
  ]));
  assertValue(liveSharpVersions.sharp, PINNED_RELEASE_TOOLCHAIN.sharp.version, "LIVE_SHARP_VERSION_MISMATCH");
  assertValue(liveSharpVersions.vips, PINNED_RELEASE_TOOLCHAIN.libvips.runtime_version, "LIVE_LIBVIPS_VERSION_MISMATCH");
  dependencyIdentity = {
    node_version: manifest.node_runtime.version,
    sharp_version: liveSharpVersions.sharp,
    libvips_package_version: libvipsPackage.version,
    libvips_runtime_version: liveSharpVersions.vips
  };
}

verifyBuildChecksums({ destination, manifest, manifestPath });
const executionTrace = commandRunner.trace();
if (staticOnly && executionTrace.candidate_path_execution_count !== 0) {
  throw new Error("STATIC_ONLY_CANDIDATE_EXECUTION_DETECTED");
}

process.stdout.write(`${JSON.stringify({
  status: staticOnly ? "BUILD_CLOSURE_STATIC_VERIFIED" : "BUILD_CLOSURE_VERIFIED",
  verification_mode: staticOnly ? "static-only" : "build-time-dynamic",
  bundle_identifier: bundleIdentifier,
  cdhash: manifest.adapter_bundle.cdhash,
  designated_requirement: manifest.adapter_bundle.designated_requirement,
  signing_certificate_sha256: manifest.adapter_bundle.signing_certificate_sha256,
  version: manifest.adapter_bundle.version,
  build_number: manifest.adapter_bundle.build_number,
  node_version: dependencyIdentity.node_version,
  sharp_version: dependencyIdentity.sharp_version,
  libvips_package_version: dependencyIdentity.libvips_package_version,
  libvips_runtime_version: dependencyIdentity.libvips_runtime_version,
  worker_file_count: dependencyIdentity.worker_file_count ?? null,
  worker_closure_sha256: dependencyIdentity.worker_closure_sha256 ?? null,
  execution_trace: executionTrace,
  source_file_count: sourceFiles.length,
  bundle_file_count: bundleFiles.length,
  source_closure_sha256: manifest.source.closure_sha256,
  bundle_closure_sha256: manifest.adapter_bundle.closure_sha256,
  manifest_sha256: sha256(fs.readFileSync(manifestPath))
}, null, 2)}\n`);

function describeTree(root, excludedDirectories = new Set()) {
  return walk(root, excludedDirectories).map((file) => describeFile(file, root));
}

function walk(directory, excludedDirectories) {
  const output = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    if (entry.name === ".DS_Store") continue;
    const candidate = path.join(directory, entry.name);
    const metadata = fs.lstatSync(candidate);
    if (metadata.isSymbolicLink()) throw new Error(`SYMLINK_NOT_ALLOWED:${candidate}`);
    if (metadata.isDirectory()) {
      if (!excludedDirectories.has(entry.name)) output.push(...walk(candidate, excludedDirectories));
      continue;
    }
    if (!metadata.isFile()) throw new Error(`NON_REGULAR_FILE_NOT_ALLOWED:${candidate}`);
    output.push(candidate);
  }
  return output;
}

function describeFile(file, base) {
  const metadata = fs.statSync(file);
  return {
    path: path.relative(base, file),
    sha256: sha256(fs.readFileSync(file)),
    size: metadata.size,
    mode: (metadata.mode & 0o777).toString(8).padStart(4, "0")
  };
}

function isMachO(file) {
  return command("/usr/bin/file", ["-b", file]).includes("Mach-O");
}

function signatureRecord(file, base) {
  command("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", file], true);
  const signature = commandCombined("/usr/bin/codesign", ["-d", "-r-", "--verbose=4", file]);
  const signingIdentifier = matchRequired(signature, /^Identifier=(.+)$/m, "SIGNING_IDENTIFIER");
  const designatedRequirement = assertSigningCertificateBinding(
    signature,
    signingIdentifier,
    signingPolicy.certificate_sha1
  );
  return {
    ...describeFile(file, base),
    signing_identifier: signingIdentifier,
    signing_certificate_sha256: signingPolicy.certificate_sha256.toUpperCase(),
    signing_certificate_proof: "designated-requirement-leaf-sha1",
    cdhash: matchRequired(signature, /^CDHash=(.+)$/m, "CDHash"),
    designated_requirement: designatedRequirement,
    hardened_runtime: /flags=.*runtime/m.test(signature),
    entitlements: readEffectiveEntitlements(
      file,
      expectedEntitlementsForPath(path.relative(base, file))
    )
  };
}

function closureDigest(files) {
  return sha256(Buffer.from(canonicalJSON(files), "utf8"));
}

function canonicalJSON(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function command(executable, args, useStderr = false) {
  const result = commandRunner.spawn(executable, args, { encoding: "utf8" });
  if (result.status !== 0) throw new Error(`COMMAND_FAILED:${executable}:${result.status}`);
  return String(useStderr ? result.stderr : result.stdout).trim();
}

function commandCombined(executable, args) {
  const result = commandRunner.spawn(executable, args, { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`COMMAND_FAILED:${executable}:${result.status}:${result.stderr}`);
  }
  return combinedProcessOutput(result.stdout, result.stderr);
}

function assertSigningCertificateBinding(signature, identifier, certificateSHA1) {
  const requirement = matchRequired(signature, /^designated => (.+)$/m, "DESIGNATED_REQUIREMENT");
  const expected = `identifier "${identifier}" and certificate leaf = H"${certificateSHA1}"`;
  assertValue(
    requirement.toUpperCase(),
    expected.toUpperCase(),
    "SIGNING_CERTIFICATE_REQUIREMENT_MISMATCH"
  );
  return requirement;
}

function matchRequired(value, pattern, name) {
  const match = value.match(pattern);
  if (!match) throw new Error(`${name}_MISSING`);
  return match[1].trim();
}

function assertEqual(observed, expected, error) {
  assertValue(canonicalJSON(observed), canonicalJSON(expected), error);
}

function assertValue(observed, expected, error) {
  if (observed !== expected) throw new Error(error);
}
