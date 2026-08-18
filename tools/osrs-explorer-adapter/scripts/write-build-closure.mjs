#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import {
  FIXED_BUNDLE_IDENTIFIER,
  FIXED_CLI_IDENTIFIER,
  FIXED_SIGNING_IDENTITY,
  PINNED_RELEASE_TOOLCHAIN,
  combinedProcessOutput,
  expectedEntitlementsForPath,
  readEffectiveEntitlements,
  validateTrustedReleaseManifest
} from "./release-verification.mjs";

const [rootArgument, expectedSourceCommit, destinationArgument, signingPolicyArgument, nodeArchiveSHA256, npmCLIArgument] = process.argv.slice(2);
if (!rootArgument || !expectedSourceCommit || !destinationArgument || !signingPolicyArgument || !nodeArchiveSHA256 || !npmCLIArgument) {
  throw new Error("usage: write-build-closure.mjs <source-root> <source-commit> <build-destination> <signing-policy> <node-archive-sha256> <npm-cli>");
}

const root = fs.realpathSync(rootArgument);
const destination = fs.realpathSync(destinationArgument);
const signingPolicyPath = fs.realpathSync(signingPolicyArgument);
const signingPolicy = JSON.parse(fs.readFileSync(signingPolicyPath, "utf8"));
const expectedCertificateSHA256 = String(signingPolicy.certificate_sha256).toUpperCase();
const expectedCertificateSHA1 = String(signingPolicy.certificate_sha1).toUpperCase();
const app = path.join(destination, "OSRS Explorer Adapter.app");
const ctl = path.join(app, "Contents", "MacOS", "osrs-explorerctl");
const sourceFiles = walk(root, {
  excludeDirectories: new Set([".build", "node_modules"])
});
const bundleFiles = walk(app);
const worktree = command("/usr/bin/git", ["-C", root, "rev-parse", "--show-toplevel"]);
const gitStatus = command("/usr/bin/git", ["-C", worktree, "status", "--porcelain=v1", "--", root]);
assertValue(command("/usr/bin/git", ["-C", worktree, "rev-parse", "HEAD"]), expectedSourceCommit, "TRUSTED_SOURCE_COMMIT_MISMATCH");
assertValue(gitStatus, "", "SOURCE_NOT_CLEAN");
const codeSignature = command("/usr/bin/codesign", ["-d", "-r-", "--verbose=4", app], { combined: true });
const bundleIdentifier = command("/usr/libexec/PlistBuddy", [
  "-c",
  "Print :CFBundleIdentifier",
  path.join(app, "Contents", "Info.plist")
]);
const version = plist("CFBundleShortVersionString");
const buildNumber = plist("CFBundleVersion");
const sourceCommit = plist("OSRSAdapterSourceCommit");
const embeddedCertificateSHA256 = plist("OSRSAdapterSigningCertificateSHA256").toUpperCase();
const certificateSHA256 = expectedCertificateSHA256;
const bundleDesignatedRequirement = assertSigningCertificateBinding(
  codeSignature,
  bundleIdentifier,
  expectedCertificateSHA1
);
const machO = bundleFiles
  .filter(isMachO)
  .map((file) => signatureRecord(file, app));
const nodePath = path.join(app, "Contents", "Resources", "node", "bin", "node");
const workerRoot = path.join(app, "Contents", "Resources", "node-worker");
const sharpPackages = bundleFiles.filter((file) => file.endsWith(`${path.sep}node_modules${path.sep}sharp${path.sep}package.json`));
if (sharpPackages.length !== 1) throw new Error(`SHARP_PACKAGE_COUNT_INVALID:${sharpPackages.length}`);
const sharpPackage = JSON.parse(fs.readFileSync(sharpPackages[0], "utf8"));
const libvipsPackagePath = path.join(workerRoot, "node_modules", "@img", "sharp-libvips-darwin-arm64", "package.json");
if (!fs.existsSync(libvipsPackagePath)) throw new Error("DARWIN_ARM64_LIBVIPS_PACKAGE_MISSING");
const libvipsPackage = JSON.parse(fs.readFileSync(libvipsPackagePath, "utf8"));
const npmCLIPath = fs.realpathSync(npmCLIArgument);
const npmPackagePath = path.resolve(path.dirname(npmCLIPath), "..", "package.json");
const npmPackage = JSON.parse(fs.readFileSync(npmPackagePath, "utf8"));
const liveSharpVersions = JSON.parse(command(nodePath, [
  "-e",
  `const sharp=require(${JSON.stringify(path.dirname(sharpPackages[0]))});process.stdout.write(JSON.stringify(sharp.versions))`
]));

assertValue(version, "0.2.0", "RELEASE_VERSION_MISMATCH");
assertValue(sourceCommit, command("/usr/bin/git", ["-C", worktree, "rev-parse", "HEAD"]), "SOURCE_COMMIT_MISMATCH");
assertValue(buildNumber, command("/usr/bin/git", ["-C", worktree, "rev-list", "--count", "HEAD"]), "BUILD_NUMBER_MISMATCH");
assertValue(embeddedCertificateSHA256, expectedCertificateSHA256.toUpperCase(), "EMBEDDED_CERTIFICATE_MISMATCH");
assertValue(certificateSHA256, expectedCertificateSHA256.toUpperCase(), "SIGNATURE_CERTIFICATE_MISMATCH");
assertValue(signingPolicy.identity, FIXED_SIGNING_IDENTITY, "SIGNING_IDENTITY_MISMATCH");
assertValue(bundleIdentifier, FIXED_BUNDLE_IDENTIFIER, "BUNDLE_IDENTIFIER_MISMATCH");
assertValue(sharpPackage.version, PINNED_RELEASE_TOOLCHAIN.sharp.version, "SHARP_VERSION_MISMATCH");
assertValue(libvipsPackage.name, PINNED_RELEASE_TOOLCHAIN.libvips.package_name, "LIBVIPS_PACKAGE_NAME_MISMATCH");
assertValue(libvipsPackage.version, PINNED_RELEASE_TOOLCHAIN.libvips.package_version, "LIBVIPS_PACKAGE_VERSION_MISMATCH");
assertValue(liveSharpVersions.sharp, PINNED_RELEASE_TOOLCHAIN.sharp.version, "LIVE_SHARP_VERSION_MISMATCH");
assertValue(liveSharpVersions.vips, PINNED_RELEASE_TOOLCHAIN.libvips.runtime_version, "LIVE_LIBVIPS_VERSION_MISMATCH");
assertValue(command(nodePath, ["--version"]), PINNED_RELEASE_TOOLCHAIN.node.version, "BUNDLED_NODE_VERSION_MISMATCH");
assertValue(nodeArchiveSHA256, PINNED_RELEASE_TOOLCHAIN.node.source_archive_sha256, "NODE_ARCHIVE_DIGEST_MISMATCH");
assertValue(sha256(fs.readFileSync(process.execPath)), PINNED_RELEASE_TOOLCHAIN.node.sha256, "CONSTRUCTION_NODE_DIGEST_MISMATCH");
assertValue(command(process.execPath, ["--version"]), PINNED_RELEASE_TOOLCHAIN.node.version, "CONSTRUCTION_NODE_VERSION_MISMATCH");
assertValue(npmPackage.version, PINNED_RELEASE_TOOLCHAIN.npm.version, "NPM_VERSION_MISMATCH");
assertValue(sha256(fs.readFileSync(npmCLIPath)), PINNED_RELEASE_TOOLCHAIN.npm.cli_sha256, "NPM_CLI_DIGEST_MISMATCH");

const sourceClosure = sourceFiles.map((file) => describe(file, root));
const bundleClosure = bundleFiles.map((file) => describe(file, app));
const manifest = {
  schema_version: 5,
  product: "OSRS Explorer Adapter",
  built_at: new Date().toISOString(),
  source: {
    root,
    git_worktree: worktree,
    git_head: command("/usr/bin/git", ["-C", worktree, "rev-parse", "HEAD"]),
    git_status_sha256: sha256(Buffer.from(gitStatus, "utf8")),
    files: sourceClosure,
    closure_sha256: closureDigest(sourceClosure)
  },
  signing_policy: {
    path: signingPolicyPath,
    identity: signingPolicy.identity,
    certificate_sha256: expectedCertificateSHA256,
    certificate_sha1: expectedCertificateSHA1
  },
  toolchains: {
    macos: command("/usr/bin/sw_vers", ["-productVersion"]),
    xcode: toolIdentity(PINNED_RELEASE_TOOLCHAIN.xcode.executable, ["-version"]),
    swift: toolIdentity(PINNED_RELEASE_TOOLCHAIN.swift.executable, ["--version"]),
    swiftc: toolIdentity(PINNED_RELEASE_TOOLCHAIN.swiftc.executable),
    node: {
      version: command(process.execPath, ["--version"]),
      sha256: sha256(fs.readFileSync(process.execPath)),
      source_archive_sha256: nodeArchiveSHA256
    },
    npm: {
      version: npmPackage.version,
      cli_sha256: sha256(fs.readFileSync(npmCLIPath))
    }
  },
  adapter_bundle: {
    path: app,
    bundle_identifier: bundleIdentifier,
    version,
    build_number: buildNumber,
    source_commit: sourceCommit,
    signing_certificate_sha256: certificateSHA256,
    signing_certificate_proof: "designated-requirement-leaf-sha1",
    signing_authority: optionalMatch(codeSignature, /^Authority=(.+)$/m),
    cdhash: matchRequired(codeSignature, /^CDHash=(.+)$/m, "CDHash"),
    designated_requirement: bundleDesignatedRequirement,
    hardened_runtime: /^(?:CodeDirectory .+ flags=.*runtime|flags=.*runtime)/m.test(codeSignature),
    entitlements: readEffectiveEntitlements(app, {}),
    files: bundleClosure,
    closure_sha256: closureDigest(bundleClosure)
  },
  mach_o: machO,
  node_runtime: {
    ...describe(nodePath, app),
    version: command(nodePath, ["--version"]),
    source_binary_sha256: sha256(fs.readFileSync(process.execPath)),
    source_archive_sha256: nodeArchiveSHA256
  },
  worker_dependencies: {
    sharp: {
      version: sharpPackage.version,
      package: describe(sharpPackages[0], app)
    },
    libvips: {
      package_name: libvipsPackage.name,
      version: libvipsPackage.version,
      runtime_version: liveSharpVersions.vips,
      package: describe(libvipsPackagePath, app)
    }
  },
  control_utility: signatureRecord(ctl, app)
};

assertValue(manifest.control_utility.signing_identifier, FIXED_CLI_IDENTIFIER, "CONTROL_UTILITY_IDENTIFIER_MISMATCH");
validateTrustedReleaseManifest(manifest, {
  sourceRoot: root,
  sourceCommit: expectedSourceCommit,
  signingPolicyPath,
  certificateSHA256: expectedCertificateSHA256,
  certificateSHA1: expectedCertificateSHA1
});

const manifestPath = path.join(destination, "ADAPTER_BUILD_CLOSURE.json");
writeAtomic(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, 0o444);
const checksumLines = [
  `${sha256(fs.readFileSync(manifestPath))}  ADAPTER_BUILD_CLOSURE.json`,
  `${manifest.source.closure_sha256}  SOURCE_CLOSURE`,
  `${manifest.adapter_bundle.closure_sha256}  ADAPTER_BUNDLE_CLOSURE`,
  `${manifest.node_runtime.sha256}  BUNDLED_NODE`,
  `${manifest.worker_dependencies.sharp.package.sha256}  SHARP_PACKAGE`,
  `${manifest.worker_dependencies.libvips.package.sha256}  LIBVIPS_PACKAGE`,
  `${manifest.control_utility.sha256}  osrs-explorerctl`
];
writeAtomic(path.join(destination, "SHA256SUMS"), `${checksumLines.join("\n")}\n`, 0o444);

function walk(directory, { excludeDirectories = new Set() } = {}) {
  const output = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    if (entry.name === ".DS_Store") continue;
    const candidate = path.join(directory, entry.name);
    const metadata = fs.lstatSync(candidate);
    if (metadata.isSymbolicLink()) throw new Error(`SYMLINK_NOT_ALLOWED:${candidate}`);
    if (metadata.isDirectory()) {
      if (!excludeDirectories.has(entry.name)) output.push(...walk(candidate, { excludeDirectories }));
      continue;
    }
    if (!metadata.isFile()) throw new Error(`NON_REGULAR_FILE_NOT_ALLOWED:${candidate}`);
    output.push(candidate);
  }
  return output;
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

function toolIdentity(executable, versionArguments) {
  const identity = {
    executable,
    sha256: sha256(fs.readFileSync(executable))
  };
  if (versionArguments) {
    identity.version = command(executable, versionArguments)
      .replace(/^swift-driver version: 1\.148\.6 /, "")
      .replaceAll("\n", " | ");
  }
  return identity;
}

function isMachO(file) {
  return command("/usr/bin/file", ["-b", file]).includes("Mach-O");
}

function signatureRecord(file, base) {
  command("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", file], { stderr: true });
  const signature = command("/usr/bin/codesign", ["-d", "-r-", "--verbose=4", file], { combined: true });
  const signingIdentifier = matchRequired(signature, /^Identifier=(.+)$/m, "SIGNING_IDENTIFIER");
  const designatedRequirement = assertSigningCertificateBinding(
    signature,
    signingIdentifier,
    expectedCertificateSHA1
  );
  return {
    ...describe(file, base),
    signing_identifier: signingIdentifier,
    signing_certificate_sha256: expectedCertificateSHA256,
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

function command(executable, args, { stderr = false, combined = false } = {}) {
  const result = spawnSync(executable, args, { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(
      `COMMAND_FAILED:${executable}:${result.status}:${String(result.stderr || result.stdout).trim()}`
    );
  }
  if (combined) return combinedProcessOutput(result.stdout, result.stderr);
  return String(stderr ? result.stderr : result.stdout).trim();
}

function plist(key) {
  return command("/usr/libexec/PlistBuddy", [
    "-c",
    `Print :${key}`,
    path.join(app, "Contents", "Info.plist")
  ]);
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

function optionalMatch(value, pattern) {
  return value.match(pattern)?.[1]?.trim() || null;
}

function assertValue(observed, expected, error) {
  if (observed !== expected) throw new Error(`${error}:observed=${observed}:expected=${expected}`);
}

function writeAtomic(destinationPath, contents, mode) {
  const temporary = `${destinationPath}.tmp-${process.pid}-${crypto.randomUUID()}`;
  fs.writeFileSync(temporary, contents, { mode: 0o600, flag: "wx" });
  const descriptor = fs.openSync(temporary, "r");
  try {
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  fs.renameSync(temporary, destinationPath);
  fs.chmodSync(destinationPath, mode);
}
