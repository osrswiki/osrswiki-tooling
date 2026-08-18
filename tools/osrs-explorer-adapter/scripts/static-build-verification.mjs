import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import {
  NODE_RUNTIME_PATH,
  PINNED_RELEASE_TOOLCHAIN
} from "./release-verification.mjs";

const WORKER_ROOT_PATH = "Contents/Resources/node-worker";
const WORKER_CLOSURE_PATH = "Contents/Resources/WORKER_RUNTIME_CLOSURE.json";
const SHARP_PACKAGE_PATH = `${WORKER_ROOT_PATH}/node_modules/sharp/package.json`;
const SHARP_NATIVE_PACKAGE_PATH = `${WORKER_ROOT_PATH}/node_modules/@img/sharp-darwin-arm64/package.json`;
const SHARP_NATIVE_PATH = `${WORKER_ROOT_PATH}/node_modules/@img/sharp-darwin-arm64/lib/sharp-darwin-arm64-${PINNED_RELEASE_TOOLCHAIN.sharp.version}.node`;
const LIBVIPS_PACKAGE_PATH = `${WORKER_ROOT_PATH}/node_modules/@img/sharp-libvips-darwin-arm64/package.json`;
const LIBVIPS_VERSIONS_PATH = `${WORKER_ROOT_PATH}/node_modules/@img/sharp-libvips-darwin-arm64/versions.json`;
const LIBVIPS_NATIVE_PATH = `${WORKER_ROOT_PATH}/node_modules/@img/sharp-libvips-darwin-arm64/lib/libvips-cpp.${PINNED_RELEASE_TOOLCHAIN.libvips.runtime_version}.dylib`;

export function createCandidateExecutionGuard({ candidateRoot, staticOnly, spawn = spawnSync }) {
  const root = realOrResolved(candidateRoot);
  let candidatePathAttemptCount = 0;
  let candidatePathExecutionCount = 0;

  return {
    spawn(executable, args, options) {
      if (isWithin(root, executable)) {
        candidatePathAttemptCount += 1;
        if (staticOnly) {
          throw new Error(`STATIC_ONLY_CANDIDATE_EXECUTION_BLOCKED:${path.resolve(executable)}`);
        }
        candidatePathExecutionCount += 1;
      }
      return spawn(executable, args, options);
    },
    trace() {
      return {
        candidate_path_attempt_count: candidatePathAttemptCount,
        candidate_path_execution_count: candidatePathExecutionCount
      };
    }
  };
}

export function verifyStaticRuntimeClosure({ appPath, manifest, bundleFiles }) {
  assertValue(manifest.node_runtime.path, NODE_RUNTIME_PATH, "NODE_RUNTIME_PATH_MISMATCH");
  assertValue(manifest.node_runtime.version, PINNED_RELEASE_TOOLCHAIN.node.version, "BUNDLED_NODE_PIN_MISMATCH");
  assertValue(
    manifest.node_runtime.source_binary_sha256,
    PINNED_RELEASE_TOOLCHAIN.node.sha256,
    "NODE_SOURCE_BINARY_DIGEST_MISMATCH"
  );
  assertValue(
    manifest.node_runtime.source_archive_sha256,
    PINNED_RELEASE_TOOLCHAIN.node.source_archive_sha256,
    "NODE_ARCHIVE_DIGEST_MISMATCH"
  );
  assertClosedFile(appPath, bundleFiles, manifest.node_runtime, "BUNDLED_NODE_MISMATCH");
  assertMachORecord(appPath, manifest, bundleFiles, NODE_RUNTIME_PATH, "NODE_RUNTIME_MACH_O_RECORD_MISSING");

  const sharpPackage = readClosedJSON(appPath, bundleFiles, SHARP_PACKAGE_PATH, "SHARP_PACKAGE_RECORD_MISMATCH");
  assertValue(sharpPackage.name, "sharp", "SHARP_PACKAGE_NAME_MISMATCH");
  assertValue(sharpPackage.version, PINNED_RELEASE_TOOLCHAIN.sharp.version, "SHARP_VERSION_MISMATCH");
  assertValue(
    sharpPackage.optionalDependencies?.["@img/sharp-darwin-arm64"],
    PINNED_RELEASE_TOOLCHAIN.sharp.version,
    "SHARP_NATIVE_DEPENDENCY_VERSION_MISMATCH"
  );
  assertValue(
    sharpPackage.optionalDependencies?.[PINNED_RELEASE_TOOLCHAIN.libvips.package_name],
    PINNED_RELEASE_TOOLCHAIN.libvips.package_version,
    "SHARP_LIBVIPS_DEPENDENCY_VERSION_MISMATCH"
  );
  assertEqual(
    closedRecord(bundleFiles, SHARP_PACKAGE_PATH, "SHARP_PACKAGE_RECORD_MISSING"),
    manifest.worker_dependencies.sharp.package,
    "SHARP_PACKAGE_RECORD_MISMATCH"
  );
  assertValue(
    bundleFiles.filter((record) => record.path.endsWith("node_modules/sharp/package.json")).length,
    1,
    "SHARP_PACKAGE_COUNT_INVALID"
  );

  const sharpNativePackage = readClosedJSON(
    appPath,
    bundleFiles,
    SHARP_NATIVE_PACKAGE_PATH,
    "SHARP_NATIVE_PACKAGE_RECORD_MISMATCH"
  );
  assertValue(sharpNativePackage.name, "@img/sharp-darwin-arm64", "SHARP_NATIVE_PACKAGE_NAME_MISMATCH");
  assertValue(sharpNativePackage.version, PINNED_RELEASE_TOOLCHAIN.sharp.version, "SHARP_NATIVE_PACKAGE_VERSION_MISMATCH");
  assertValue(
    sharpNativePackage.optionalDependencies?.[PINNED_RELEASE_TOOLCHAIN.libvips.package_name],
    PINNED_RELEASE_TOOLCHAIN.libvips.package_version,
    "SHARP_NATIVE_LIBVIPS_DEPENDENCY_VERSION_MISMATCH"
  );
  assertMachORecord(appPath, manifest, bundleFiles, SHARP_NATIVE_PATH, "SHARP_NATIVE_MACH_O_RECORD_MISSING");

  const libvipsPackage = readClosedJSON(appPath, bundleFiles, LIBVIPS_PACKAGE_PATH, "LIBVIPS_PACKAGE_RECORD_MISMATCH");
  assertValue(libvipsPackage.name, PINNED_RELEASE_TOOLCHAIN.libvips.package_name, "LIBVIPS_PACKAGE_NAME_MISMATCH");
  assertValue(libvipsPackage.version, PINNED_RELEASE_TOOLCHAIN.libvips.package_version, "LIBVIPS_PACKAGE_VERSION_MISMATCH");
  assertValue(
    libvipsPackage.exports?.["./binary"],
    `./lib/libvips-cpp.${PINNED_RELEASE_TOOLCHAIN.libvips.runtime_version}.dylib`,
    "LIBVIPS_BINARY_EXPORT_MISMATCH"
  );
  assertEqual(
    closedRecord(bundleFiles, LIBVIPS_PACKAGE_PATH, "LIBVIPS_PACKAGE_RECORD_MISSING"),
    manifest.worker_dependencies.libvips.package,
    "LIBVIPS_PACKAGE_RECORD_MISMATCH"
  );
  assertValue(
    bundleFiles.filter((record) => record.path.endsWith("node_modules/@img/sharp-libvips-darwin-arm64/package.json")).length,
    1,
    "LIBVIPS_PACKAGE_COUNT_INVALID"
  );
  const libvipsVersions = readClosedJSON(appPath, bundleFiles, LIBVIPS_VERSIONS_PATH, "LIBVIPS_VERSIONS_RECORD_MISMATCH");
  assertValue(libvipsVersions.vips, PINNED_RELEASE_TOOLCHAIN.libvips.runtime_version, "STATIC_LIBVIPS_RUNTIME_VERSION_MISMATCH");
  assertValue(
    manifest.worker_dependencies.libvips.runtime_version,
    libvipsVersions.vips,
    "LIBVIPS_RUNTIME_RECORD_MISMATCH"
  );
  assertMachORecord(appPath, manifest, bundleFiles, LIBVIPS_NATIVE_PATH, "LIBVIPS_NATIVE_MACH_O_RECORD_MISSING");

  const workerRoot = path.join(appPath, WORKER_ROOT_PATH);
  const workerClosure = readClosedJSON(appPath, bundleFiles, WORKER_CLOSURE_PATH, "WORKER_RUNTIME_CLOSURE_RECORD_MISMATCH");
  assertValue(workerClosure.schema_version, 1, "WORKER_RUNTIME_CLOSURE_SCHEMA_UNSUPPORTED");
  const workerFiles = describeTree(workerRoot);
  assertEqual(workerFiles, workerClosure.files, "WORKER_RUNTIME_FILES_MISMATCH");
  assertValue(closureDigest(workerFiles), workerClosure.closure_sha256, "WORKER_RUNTIME_CLOSURE_DIGEST_MISMATCH");

  return {
    node_version: manifest.node_runtime.version,
    sharp_version: sharpPackage.version,
    libvips_package_version: libvipsPackage.version,
    libvips_runtime_version: libvipsVersions.vips,
    worker_file_count: workerFiles.length,
    worker_closure_sha256: workerClosure.closure_sha256
  };
}

export function verifyBuildChecksums({ destination, manifest, manifestPath }) {
  const expected = [
    `${sha256(fs.readFileSync(manifestPath))}  ADAPTER_BUILD_CLOSURE.json`,
    `${manifest.source.closure_sha256}  SOURCE_CLOSURE`,
    `${manifest.adapter_bundle.closure_sha256}  ADAPTER_BUNDLE_CLOSURE`,
    `${manifest.node_runtime.sha256}  BUNDLED_NODE`,
    `${manifest.worker_dependencies.sharp.package.sha256}  SHARP_PACKAGE`,
    `${manifest.worker_dependencies.libvips.package.sha256}  LIBVIPS_PACKAGE`,
    `${manifest.control_utility.sha256}  osrs-explorerctl`,
    ""
  ].join("\n");
  assertValue(fs.readFileSync(path.join(destination, "SHA256SUMS"), "utf8"), expected, "SHA256SUMS_MISMATCH");
}

function readClosedJSON(appPath, bundleFiles, relativePath, error) {
  const record = closedRecord(bundleFiles, relativePath, `${error}:MISSING`);
  assertClosedFile(appPath, bundleFiles, record, error);
  return JSON.parse(fs.readFileSync(path.join(appPath, relativePath), "utf8"));
}

function assertMachORecord(appPath, manifest, bundleFiles, relativePath, error) {
  const closed = closedRecord(bundleFiles, relativePath, `${error}:BUNDLE_RECORD_MISSING`);
  assertClosedFile(appPath, bundleFiles, closed, `${error}:FILE_MISMATCH`);
  const signed = manifest.mach_o.find((record) => record.path === relativePath);
  if (!signed) throw new Error(error);
  assertValue(signed.sha256, closed.sha256, `${error}:DIGEST_MISMATCH`);
}

function assertClosedFile(appPath, bundleFiles, expected, error) {
  const closed = closedRecord(bundleFiles, expected.path, `${error}:BUNDLE_RECORD_MISSING`);
  assertEqual(closed, pickFileRecord(expected), `${error}:MANIFEST_RECORD_MISMATCH`);
  assertEqual(describeFile(path.join(appPath, expected.path), appPath), closed, error);
}

function closedRecord(bundleFiles, relativePath, error) {
  const records = bundleFiles.filter((record) => record.path === relativePath);
  if (records.length !== 1) throw new Error(`${error}:count=${records.length}`);
  return records[0];
}

function pickFileRecord(record) {
  return {
    path: record.path,
    sha256: record.sha256,
    size: record.size,
    mode: record.mode
  };
}

function describeTree(root) {
  return walk(root).map((file) => describeFile(file, root));
}

function walk(directory) {
  const output = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    if (entry.name === ".DS_Store") continue;
    const candidate = path.join(directory, entry.name);
    const metadata = fs.lstatSync(candidate);
    if (metadata.isSymbolicLink()) throw new Error(`SYMLINK_NOT_ALLOWED:${candidate}`);
    if (metadata.isDirectory()) output.push(...walk(candidate));
    else if (metadata.isFile()) output.push(candidate);
    else throw new Error(`NON_REGULAR_FILE_NOT_ALLOWED:${candidate}`);
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

function assertEqual(observed, expected, error) {
  assertValue(canonicalJSON(observed), canonicalJSON(expected), error);
}

function assertValue(observed, expected, error) {
  if (observed !== expected) throw new Error(error);
}

function realOrResolved(value) {
  const resolved = path.resolve(value);
  return fs.existsSync(resolved) ? fs.realpathSync(resolved) : resolved;
}

function isWithin(root, candidate) {
  const lexical = path.resolve(candidate);
  const resolved = realOrResolved(candidate);
  return lexical === root
    || lexical.startsWith(`${root}${path.sep}`)
    || resolved === root
    || resolved.startsWith(`${root}${path.sep}`);
}
