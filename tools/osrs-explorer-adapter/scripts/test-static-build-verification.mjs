import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  createCandidateExecutionGuard,
  verifyBuildChecksums,
  verifyStaticRuntimeClosure
} from "./static-build-verification.mjs";
import {
  NODE_RUNTIME_PATH,
  PINNED_RELEASE_TOOLCHAIN
} from "./release-verification.mjs";

test("static-only guard blocks injected candidate execution before spawn", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "osrs-static-spawn-guard."));
  const executable = path.join(root, "OSRS Explorer Adapter.app/Contents/Resources/node/bin/node");
  fs.mkdirSync(path.dirname(executable), { recursive: true });
  fs.writeFileSync(executable, "candidate-node");
  let spawnCalls = 0;
  const guard = createCandidateExecutionGuard({
    candidateRoot: root,
    staticOnly: true,
    spawn() {
      spawnCalls += 1;
      return { status: 0, stdout: "", stderr: "" };
    }
  });

  assert.throws(
    () => guard.spawn(executable, ["--version"], { encoding: "utf8" }),
    /STATIC_ONLY_CANDIDATE_EXECUTION_BLOCKED/
  );
  assert.equal(spawnCalls, 0);
  assert.deepEqual(guard.trace(), {
    candidate_path_attempt_count: 1,
    candidate_path_execution_count: 0
  });
  fs.rmSync(root, { recursive: true, force: true });
});

test("dynamic build-time guard preserves authorized candidate runtime probes", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "osrs-dynamic-spawn-guard."));
  const executable = path.join(root, "OSRS Explorer Adapter.app/Contents/Resources/node/bin/node");
  fs.mkdirSync(path.dirname(executable), { recursive: true });
  fs.writeFileSync(executable, "candidate-node");
  let spawnCalls = 0;
  const guard = createCandidateExecutionGuard({
    candidateRoot: root,
    staticOnly: false,
    spawn() {
      spawnCalls += 1;
      return { status: 0, stdout: "v26.4.0\n", stderr: "" };
    }
  });

  assert.equal(guard.spawn(executable, ["--version"], { encoding: "utf8" }).status, 0);
  assert.equal(spawnCalls, 1);
  assert.deepEqual(guard.trace(), {
    candidate_path_attempt_count: 1,
    candidate_path_execution_count: 1
  });
  fs.rmSync(root, { recursive: true, force: true });
});

test("closure entry point confines live Node and Sharp probes to dynamic mode", () => {
  const source = fs.readFileSync(new URL("./verify-build-closure.mjs", import.meta.url), "utf8");
  const branchStart = source.indexOf("if (staticOnly)");
  const branch = source.slice(branchStart, source.indexOf("\nverifyBuildChecksums", branchStart));
  const [staticBranch, dynamicBranch] = branch.split("} else {");
  assert.doesNotMatch(staticBranch, /nodePath.*--version|require\(.*sharp/);
  assert.match(dynamicBranch, /command\(nodePath, \["--version"\]\)/);
  assert.match(dynamicBranch, /const sharp=require/);
});

test("static runtime verification proves pinned Node, Sharp, libvips, native members, and worker closure", () => {
  const fixture = staticFixture();
  try {
    const result = verifyStaticRuntimeClosure(fixture);
    assert.equal(result.node_version, "v26.4.0");
    assert.equal(result.sharp_version, "0.35.3");
    assert.equal(result.libvips_runtime_version, "8.18.3");
    assert.equal(result.worker_file_count, fixture.workerFileCount);
    assert.match(result.worker_closure_sha256, /^[0-9a-f]{64}$/);
  } finally {
    fixture.dispose();
  }
});

for (const [name, options, expression] of [
  ["Node source record drift", { nodeSourceSHA256: "0".repeat(64) }, /NODE_SOURCE_BINARY_DIGEST_MISMATCH/],
  ["Sharp package drift", { sharpVersion: "0.35.2" }, /SHARP_VERSION_MISMATCH/],
  ["libvips versions drift", { libvipsRuntimeVersion: "8.18.2" }, /STATIC_LIBVIPS_RUNTIME_VERSION_MISMATCH/],
  ["missing Sharp native signature record", { omitSharpMachO: true }, /SHARP_NATIVE_MACH_O_RECORD_MISSING/]
]) {
  test(`static runtime verification rejects ${name}`, () => {
    const fixture = staticFixture(options);
    try {
      assert.throws(() => verifyStaticRuntimeClosure(fixture), expression);
    } finally {
      fixture.dispose();
    }
  });
}

test("static runtime verification rejects worker closure drift", () => {
  const fixture = staticFixture();
  try {
    fs.writeFileSync(path.join(fixture.appPath, "Contents/Resources/node-worker/late-file"), "late");
    assert.throws(() => verifyStaticRuntimeClosure(fixture), /WORKER_RUNTIME_FILES_MISMATCH/);
  } finally {
    fixture.dispose();
  }
});

for (const [name, relativePath, expression] of [
  ["Node signed-binary drift", NODE_RUNTIME_PATH, /BUNDLED_NODE_MISMATCH/],
  [
    "Sharp native-member drift",
    `Contents/Resources/node-worker/node_modules/@img/sharp-darwin-arm64/lib/sharp-darwin-arm64-${PINNED_RELEASE_TOOLCHAIN.sharp.version}.node`,
    /SHARP_NATIVE_MACH_O_RECORD_MISSING:FILE_MISMATCH/
  ],
  [
    "libvips native-member drift",
    `Contents/Resources/node-worker/node_modules/@img/sharp-libvips-darwin-arm64/lib/libvips-cpp.${PINNED_RELEASE_TOOLCHAIN.libvips.runtime_version}.dylib`,
    /LIBVIPS_NATIVE_MACH_O_RECORD_MISSING:FILE_MISMATCH/
  ]
]) {
  test(`static runtime verification rejects ${name}`, () => {
    const fixture = staticFixture();
    try {
      fs.appendFileSync(path.join(fixture.appPath, relativePath), "drift");
      assert.throws(() => verifyStaticRuntimeClosure(fixture), expression);
    } finally {
      fixture.dispose();
    }
  });
}

test("static checksum verification rejects drift", () => {
  const fixture = staticFixture();
  try {
    const destination = path.dirname(fixture.appPath);
    const manifestPath = path.join(destination, "ADAPTER_BUILD_CLOSURE.json");
    const manifest = {
      ...fixture.manifest,
      source: { closure_sha256: "1".repeat(64) },
      adapter_bundle: { closure_sha256: "2".repeat(64) },
      control_utility: { sha256: "3".repeat(64) }
    };
    fs.writeFileSync(manifestPath, `${JSON.stringify(manifest)}\n`);
    fs.writeFileSync(path.join(destination, "SHA256SUMS"), "hostile\n");
    assert.throws(
      () => verifyBuildChecksums({ destination, manifest, manifestPath }),
      /SHA256SUMS_MISMATCH/
    );
  } finally {
    fixture.dispose();
  }
});

function staticFixture({
  nodeSourceSHA256 = PINNED_RELEASE_TOOLCHAIN.node.sha256,
  sharpVersion = PINNED_RELEASE_TOOLCHAIN.sharp.version,
  libvipsRuntimeVersion = PINNED_RELEASE_TOOLCHAIN.libvips.runtime_version,
  omitSharpMachO = false
} = {}) {
  const destination = fs.mkdtempSync(path.join(os.tmpdir(), "osrs-static-verifier."));
  const appPath = path.join(destination, "OSRS Explorer Adapter.app");
  const workerRoot = path.join(appPath, "Contents/Resources/node-worker");
  const relative = (value) => path.join(appPath, value);
  const sharpPackagePath = "Contents/Resources/node-worker/node_modules/sharp/package.json";
  const sharpNativePackagePath = "Contents/Resources/node-worker/node_modules/@img/sharp-darwin-arm64/package.json";
  const sharpNativePath = `Contents/Resources/node-worker/node_modules/@img/sharp-darwin-arm64/lib/sharp-darwin-arm64-${PINNED_RELEASE_TOOLCHAIN.sharp.version}.node`;
  const libvipsPackagePath = "Contents/Resources/node-worker/node_modules/@img/sharp-libvips-darwin-arm64/package.json";
  const libvipsVersionsPath = "Contents/Resources/node-worker/node_modules/@img/sharp-libvips-darwin-arm64/versions.json";
  const libvipsNativePath = `Contents/Resources/node-worker/node_modules/@img/sharp-libvips-darwin-arm64/lib/libvips-cpp.${PINNED_RELEASE_TOOLCHAIN.libvips.runtime_version}.dylib`;

  write(relative(NODE_RUNTIME_PATH), "signed-node", 0o755);
  write(relative(sharpPackagePath), JSON.stringify({
    name: "sharp",
    version: sharpVersion,
    optionalDependencies: {
      "@img/sharp-darwin-arm64": PINNED_RELEASE_TOOLCHAIN.sharp.version,
      [PINNED_RELEASE_TOOLCHAIN.libvips.package_name]: PINNED_RELEASE_TOOLCHAIN.libvips.package_version
    }
  }));
  write(relative(sharpNativePackagePath), JSON.stringify({
    name: "@img/sharp-darwin-arm64",
    version: PINNED_RELEASE_TOOLCHAIN.sharp.version,
    optionalDependencies: {
      [PINNED_RELEASE_TOOLCHAIN.libvips.package_name]: PINNED_RELEASE_TOOLCHAIN.libvips.package_version
    }
  }));
  write(relative(sharpNativePath), "sharp-native");
  write(relative(libvipsPackagePath), JSON.stringify({
    name: PINNED_RELEASE_TOOLCHAIN.libvips.package_name,
    version: PINNED_RELEASE_TOOLCHAIN.libvips.package_version,
    exports: { "./binary": `./lib/libvips-cpp.${PINNED_RELEASE_TOOLCHAIN.libvips.runtime_version}.dylib` }
  }));
  write(relative(libvipsVersionsPath), JSON.stringify({ vips: libvipsRuntimeVersion }));
  write(relative(libvipsNativePath), "libvips-native");
  write(path.join(workerRoot, "package.json"), JSON.stringify({ name: "worker" }));

  const workerFiles = describeTree(workerRoot);
  write(relative("Contents/Resources/WORKER_RUNTIME_CLOSURE.json"), JSON.stringify({
    schema_version: 1,
    files: workerFiles,
    closure_sha256: closureDigest(workerFiles)
  }));
  const bundleFiles = describeTree(appPath);
  const nodeRecord = record(bundleFiles, NODE_RUNTIME_PATH);
  const sharpRecord = record(bundleFiles, sharpPackagePath);
  const libvipsRecord = record(bundleFiles, libvipsPackagePath);
  const machOPaths = [NODE_RUNTIME_PATH, libvipsNativePath];
  if (!omitSharpMachO) machOPaths.push(sharpNativePath);
  const manifest = {
    node_runtime: {
      ...nodeRecord,
      version: PINNED_RELEASE_TOOLCHAIN.node.version,
      source_binary_sha256: nodeSourceSHA256,
      source_archive_sha256: PINNED_RELEASE_TOOLCHAIN.node.source_archive_sha256
    },
    worker_dependencies: {
      sharp: { version: PINNED_RELEASE_TOOLCHAIN.sharp.version, package: sharpRecord },
      libvips: {
        package_name: PINNED_RELEASE_TOOLCHAIN.libvips.package_name,
        version: PINNED_RELEASE_TOOLCHAIN.libvips.package_version,
        runtime_version: PINNED_RELEASE_TOOLCHAIN.libvips.runtime_version,
        package: libvipsRecord
      }
    },
    mach_o: machOPaths.map((member) => ({ path: member, sha256: record(bundleFiles, member).sha256 }))
  };
  return {
    appPath,
    manifest,
    bundleFiles,
    workerFileCount: workerFiles.length,
    dispose: () => fs.rmSync(destination, { recursive: true, force: true })
  };
}

function write(destination, contents, mode = 0o644) {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, contents, { mode });
  fs.chmodSync(destination, mode);
}

function record(records, relativePath) {
  return records.find((value) => value.path === relativePath);
}

function describeTree(root) {
  return walk(root).map((file) => describe(file, root));
}

function walk(directory) {
  const output = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const candidate = path.join(directory, entry.name);
    if (entry.isDirectory()) output.push(...walk(candidate));
    else output.push(candidate);
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
