import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const workerRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const derivedRoot = path.join(workerRoot, "derived", "reviewed-v4");
const sourcePackage = process.argv[2];
const writeManifest = process.argv.includes("--write");
const expectedPackage = {
  runtime_manifest_sha256: "ad65bfb911dd164b40b6d3cb4cef89daa276fbb9aaf53550db19b72c1fbeb9ba",
  sha256sums_sha256: "3c7eef565df6d87b868d76486ba58ebc7978441f88be0a0528ca8324d416ae6d"
};

if (!sourcePackage) throw new Error("SOURCE_PACKAGE_PATH_REQUIRED");
const shaSumsPath = path.join(sourcePackage, "SHA256SUMS");
const runtimeManifestPath = path.join(sourcePackage, "EXPLORER_V4_RUNTIME_PACKAGE.json");
assertEqual(await digestFile(shaSumsPath), expectedPackage.sha256sums_sha256, "SHA256SUMS");
assertEqual(await digestFile(runtimeManifestPath), expectedPackage.runtime_manifest_sha256, "RUNTIME_MANIFEST");

const declared = new Map(
  (await fs.readFile(shaSumsPath, "utf8"))
    .trim()
    .split("\n")
    .map((line) => {
      const [digest, relative] = line.split(/\s+/, 2);
      return [relative.replace(/^\.\//, ""), digest];
    })
);
const mappings = [
  ["source/explorer-v4-runtime.mjs", "src/explorer-v4-runtime.mjs"],
  ["source/execution-lifecycle.mjs", "src/execution-lifecycle.mjs"],
  ["config/explorer-v4-config.json", "config/explorer-v4-config.json"],
  ["worklist/explorer-v4-worklist.json", "worklist/explorer-v4-worklist.json"]
];
for (const relative of await files(path.join(derivedRoot, "templates"))) {
  mappings.push([`templates/${relative}`, `templates/${relative}`]);
}
for (const relative of await files(path.join(derivedRoot, "fixtures", "controller-status"))) {
  mappings.push([
    `fixtures/controller-status/${relative}`,
    `fixtures/controller-status/${relative}`
  ]);
}

const copied = [];
for (const [derivedPath, sourcePath] of mappings) {
  const expected = declared.get(sourcePath);
  if (!expected) throw new Error(`SOURCE_MEMBER_UNDECLARED:${sourcePath}`);
  const derivedDigest = await digestFile(path.join(derivedRoot, derivedPath));
  const liveSourceDigest = await digestFile(path.join(sourcePackage, sourcePath));
  assertEqual(liveSourceDigest, expected, `SOURCE_MEMBER:${sourcePath}`);
  assertEqual(derivedDigest, expected, `DERIVED_COPY:${derivedPath}`);
  copied.push({ derived_path: derivedPath, source_path: sourcePath, sha256: expected });
}

const exactRuntime = await fs.readFile(
  path.join(derivedRoot, "source", "explorer-v4-runtime.mjs"),
  "utf8"
);
const oldBinding = `const sharp = require(\n  "/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/sharp/lib/index.js"\n);`;
const newBinding = `const sharp = require("sharp");\nsharp.block({\n  operation: ["VipsForeignLoadNsgif", "VipsForeignLoadTiff", "VipsForeignLoadVips"]\n});`;
if (!exactRuntime.includes(oldBinding)) throw new Error("SOURCE_SHARP_BINDING_NOT_FOUND");
const expectedDerivedRuntime = exactRuntime.replace(oldBinding, newBinding);
const actualDerivedRuntime = await fs.readFile(
  path.join(derivedRoot, "runtime", "explorer-v4-runtime.mjs"),
  "utf8"
);
assertEqual(actualDerivedRuntime, expectedDerivedRuntime, "DERIVED_RUNTIME_TRANSFORM");
if (/ChatGPT\.app|nodeRepl|setupComputerUseRuntime/.test(actualDerivedRuntime)) {
  throw new Error("DERIVED_RUNTIME_RETAINS_CODEX_RUNTIME_BINDING");
}

const manifest = {
  schema_version: 1,
  source_package: "explorer-v4cr4-computer-use-binding-correction-017-20260731T054118Z",
  source_package_identity: expectedPackage,
  copied_members: copied.sort((a, b) => a.derived_path.localeCompare(b.derived_path)),
  runtime_derivation: {
    source_path: "source/explorer-v4-runtime.mjs",
    source_sha256: sha256(exactRuntime),
    derived_path: "runtime/explorer-v4-runtime.mjs",
    derived_sha256: sha256(actualDerivedRuntime),
    transformations: [
      "replace ChatGPT-bundled sharp absolute import with package-local sharp@0.35.3",
      "block VipsForeignLoadNsgif, VipsForeignLoadTiff, and VipsForeignLoadVips per GHSA-f88m-g3jw-g9cj"
    ],
    other_source_changes: 0
  }
};
const manifestBytes = `${JSON.stringify(manifest, null, 2)}\n`;
const manifestPath = path.join(derivedRoot, "DERIVATION_MANIFEST.json");
if (writeManifest) {
  await fs.writeFile(manifestPath, manifestBytes, { flag: "wx", mode: 0o444 });
  await fs.chmod(manifestPath, 0o444);
} else {
  const existing = await fs.readFile(manifestPath, "utf8");
  assertEqual(existing, manifestBytes, "DERIVATION_MANIFEST");
}
process.stdout.write(`${JSON.stringify({ ok: true, manifest_sha256: sha256(manifestBytes), copied_members: copied.length })}\n`);

async function files(root) {
  const output = [];
  for (const entry of await fs.readdir(root, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      for (const child of await files(path.join(root, entry.name))) {
        output.push(path.join(entry.name, child));
      }
    } else if (entry.isFile()) output.push(entry.name);
  }
  return output.sort();
}

async function digestFile(file) {
  return sha256(await fs.readFile(file));
}

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function assertEqual(actual, expected, label) {
  if (actual !== expected) throw new Error(`${label}_MISMATCH`);
}
