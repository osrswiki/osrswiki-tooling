#!/usr/bin/env node

import { spawnSync } from "node:child_process";
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

const [buildArgument, installedArgument, sourceRootArgument, sourceCommit, signingPolicyArgument] = process.argv.slice(2);
if (!buildArgument || !installedArgument || !sourceRootArgument || !sourceCommit || !signingPolicyArgument) {
  throw new Error("usage: verify-installed-bundle.mjs <build-destination> <installed-app> <source-root> <source-commit> <signing-policy>");
}
const build = fs.realpathSync(buildArgument);
const installed = fs.realpathSync(installedArgument);
const sourceRoot = fs.realpathSync(sourceRootArgument);
const signingPolicyPath = fs.realpathSync(signingPolicyArgument);
const signingPolicy = JSON.parse(fs.readFileSync(signingPolicyPath, "utf8"));
const manifest = JSON.parse(fs.readFileSync(path.join(build, "ADAPTER_BUILD_CLOSURE.json"), "utf8"));
validateTrustedReleaseManifest(manifest, {
  sourceRoot,
  sourceCommit,
  signingPolicyPath,
  certificateSHA256: signingPolicy.certificate_sha256,
  certificateSHA1: signingPolicy.certificate_sha1
});
assertValue(command("/usr/bin/git", ["-C", sourceRoot, "rev-parse", "HEAD"]), sourceCommit, "SOURCE_HEAD_MISMATCH");
assertValue(command("/usr/bin/git", ["-C", sourceRoot, "status", "--porcelain=v1", "--", sourceRoot]), "", "SOURCE_NOT_CLEAN");
const files = walk(installed).map((file) => describe(file, installed));
if (canonicalJSON(files) !== canonicalJSON(manifest.adapter_bundle.files)) {
  throw new Error("INSTALLED_BUNDLE_FILE_CLOSURE_MISMATCH");
}
if (sha256(Buffer.from(canonicalJSON(files), "utf8")) !== manifest.adapter_bundle.closure_sha256) {
  throw new Error("INSTALLED_BUNDLE_DIGEST_MISMATCH");
}
command("/usr/bin/codesign", ["--verify", "--strict", "--deep", "--verbose=2", installed], true);
const signature = commandCombined("/usr/bin/codesign", ["-d", "-r-", "--verbose=4", installed]);
assertValue(match(signature, /^CDHash=(.+)$/m), manifest.adapter_bundle.cdhash, "INSTALLED_CDHASH_MISMATCH");
const bundleDesignatedRequirement = assertSigningCertificateBinding(
  signature,
  manifest.adapter_bundle.bundle_identifier,
  signingPolicy.certificate_sha1
);
assertValue(bundleDesignatedRequirement, manifest.adapter_bundle.designated_requirement, "INSTALLED_REQUIREMENT_MISMATCH");
assertValue(
  canonicalJSON(readEffectiveEntitlements(installed, {})),
  canonicalJSON(manifest.adapter_bundle.entitlements),
  "INSTALLED_BUNDLE_ENTITLEMENTS_MISMATCH"
);
const machO = files
  .map((file) => path.join(installed, file.path))
  .filter(isMachO)
  .map((file) => signatureRecord(file, installed));
if (canonicalJSON(machO) !== canonicalJSON(manifest.mach_o)) {
  throw new Error("INSTALLED_MACH_O_CLOSURE_MISMATCH");
}
const nodePath = path.join(installed, manifest.node_runtime.path);
assertValue(command(nodePath, ["--version"]), PINNED_RELEASE_TOOLCHAIN.node.version, "INSTALLED_NODE_VERSION_MISMATCH");
assertValue(sha256(fs.readFileSync(nodePath)), manifest.node_runtime.sha256, "INSTALLED_NODE_DIGEST_MISMATCH");
const sharpPackagePath = path.join(installed, manifest.worker_dependencies.sharp.package.path);
const sharpPackage = JSON.parse(fs.readFileSync(sharpPackagePath, "utf8"));
assertValue(sharpPackage.name, "sharp", "INSTALLED_SHARP_PACKAGE_NAME_MISMATCH");
assertValue(sharpPackage.version, PINNED_RELEASE_TOOLCHAIN.sharp.version, "INSTALLED_SHARP_VERSION_MISMATCH");
const libvipsPackagePath = path.join(installed, manifest.worker_dependencies.libvips.package.path);
const libvipsPackage = JSON.parse(fs.readFileSync(libvipsPackagePath, "utf8"));
assertValue(libvipsPackage.name, PINNED_RELEASE_TOOLCHAIN.libvips.package_name, "INSTALLED_LIBVIPS_PACKAGE_NAME_MISMATCH");
assertValue(libvipsPackage.version, PINNED_RELEASE_TOOLCHAIN.libvips.package_version, "INSTALLED_LIBVIPS_PACKAGE_VERSION_MISMATCH");
const liveSharpVersions = JSON.parse(command(nodePath, [
  "-e",
  `const sharp=require(${JSON.stringify(path.dirname(sharpPackagePath))});process.stdout.write(JSON.stringify(sharp.versions))`
]));
assertValue(liveSharpVersions.sharp, PINNED_RELEASE_TOOLCHAIN.sharp.version, "INSTALLED_LIVE_SHARP_VERSION_MISMATCH");
assertValue(liveSharpVersions.vips, PINNED_RELEASE_TOOLCHAIN.libvips.runtime_version, "INSTALLED_LIVE_LIBVIPS_VERSION_MISMATCH");
process.stdout.write(`${JSON.stringify({
  status: "INSTALLED_BUNDLE_VERIFIED",
  path: installed,
  closure_sha256: manifest.adapter_bundle.closure_sha256,
  cdhash: manifest.adapter_bundle.cdhash,
  designated_requirement: manifest.adapter_bundle.designated_requirement,
  sharp_version: liveSharpVersions.sharp,
  libvips_runtime_version: liveSharpVersions.vips
}, null, 2)}\n`);

function walk(directory) {
  const result = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    if (entry.name === ".DS_Store") continue;
    const candidate = path.join(directory, entry.name);
    const metadata = fs.lstatSync(candidate);
    if (metadata.isSymbolicLink()) throw new Error(`INSTALLED_SYMLINK_FORBIDDEN:${candidate}`);
    if (metadata.isDirectory()) result.push(...walk(candidate));
    else if (metadata.isFile()) result.push(candidate);
    else throw new Error(`INSTALLED_NON_REGULAR_FILE:${candidate}`);
  }
  return result;
}

function describe(file, base) {
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
  const signingIdentifier = match(signature, /^Identifier=(.+)$/m);
  const designatedRequirement = assertSigningCertificateBinding(
    signature,
    signingIdentifier,
    signingPolicy.certificate_sha1
  );
  return {
    ...describe(file, base),
    signing_identifier: signingIdentifier,
    signing_certificate_sha256: signingPolicy.certificate_sha256.toUpperCase(),
    signing_certificate_proof: "designated-requirement-leaf-sha1",
    cdhash: match(signature, /^CDHash=(.+)$/m),
    designated_requirement: designatedRequirement,
    hardened_runtime: /flags=.*runtime/m.test(signature),
    entitlements: readEffectiveEntitlements(
      file,
      expectedEntitlementsForPath(path.relative(base, file))
    )
  };
}

function command(executable, args, stderr = false) {
  const result = spawnSync(executable, args, { encoding: "utf8" });
  if (result.status !== 0) throw new Error(`COMMAND_FAILED:${executable}:${result.status}:${result.stderr}`);
  return String(stderr ? result.stderr : result.stdout).trim();
}

function commandCombined(executable, args) {
  const result = spawnSync(executable, args, { encoding: "utf8" });
  if (result.status !== 0) throw new Error(`COMMAND_FAILED:${executable}:${result.status}:${result.stderr}`);
  return combinedProcessOutput(result.stdout, result.stderr);
}

function match(value, expression) {
  const result = value.match(expression);
  if (!result) throw new Error(`SIGNATURE_FIELD_MISSING:${expression}`);
  return result[1].trim();
}

function assertValue(observed, expected, error) {
  if (observed !== expected) throw new Error(error);
}

function assertSigningCertificateBinding(signature, identifier, certificateSHA1) {
  const requirement = match(signature, /^designated => (.+)$/m);
  const expected = `identifier "${identifier}" and certificate leaf = H"${certificateSHA1}"`;
  assertValue(
    requirement.toUpperCase(),
    expected.toUpperCase(),
    "SIGNING_CERTIFICATE_REQUIREMENT_MISMATCH"
  );
  return requirement;
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
