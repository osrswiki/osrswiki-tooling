import { spawnSync } from "node:child_process";
import crypto from "node:crypto";

export const FIXED_BUNDLE_IDENTIFIER = "com.omiyawaki.osrswiki.explorer-adapter";
export const FIXED_CLI_IDENTIFIER = "com.omiyawaki.osrswiki.explorer-adapter.cli";
export const FIXED_SIGNING_IDENTITY = "OSRS Explorer Adapter Local Signing";
export const NODE_RUNTIME_PATH = "Contents/Resources/node/bin/node";
export const NODE_RUNTIME_ENTITLEMENTS = Object.freeze({
  "com.apple.security.cs.allow-jit": true,
  "com.apple.security.cs.disable-library-validation": true
});
const NO_ENTITLEMENTS = Object.freeze({});
export const PINNED_RELEASE_TOOLCHAIN = Object.freeze({
  xcode: Object.freeze({
    executable: "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild",
    version: "Xcode 26.6 | Build version 17F113",
    sha256: "d508f0e1901151843804e4af512d4587ad0e422039e43e14abf22792360ad3d4"
  }),
  swift: Object.freeze({
    executable: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift",
    version: "Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101) | Target: arm64-apple-macosx26.0",
    sha256: "2ed38571e92c0283091838c1649e27650ad9c99950288e883c7b2dc6c4ce89fb"
  }),
  swiftc: Object.freeze({
    executable: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc",
    sha256: "2ed38571e92c0283091838c1649e27650ad9c99950288e883c7b2dc6c4ce89fb"
  }),
  node: Object.freeze({
    version: "v26.4.0",
    sha256: "d23e520f5bcd497bdd0c6a6242356a4fd255abaceba7c3549727caacb936ddae",
    source_archive_sha256: "bef4c7e75087c029835f519a7ba640eba52fa617fadb3a9049828ff3b45b57dd"
  }),
  npm: Object.freeze({
    version: "11.17.0",
    cli_sha256: "8e5f6f3429f8cdbe693cdc29904e9d5a7b127a494bd15c804bd54c7403bfcbe7"
  }),
  sharp: Object.freeze({ version: "0.35.3" }),
  libvips: Object.freeze({
    package_name: "@img/sharp-libvips-darwin-arm64",
    package_version: "1.3.2",
    runtime_version: "8.18.3"
  })
});

export function validateTrustedReleaseManifest(manifest, trusted) {
  assertValue(manifest.schema_version, 5, "BUILD_CLOSURE_SCHEMA_UNSUPPORTED");
  assertValue(manifest.source.root, trusted.sourceRoot, "TRUSTED_SOURCE_ROOT_MISMATCH");
  assertValue(manifest.source.git_head, trusted.sourceCommit, "TRUSTED_SOURCE_COMMIT_MISMATCH");
  assertValue(manifest.source.git_status_sha256, sha256(Buffer.alloc(0)), "SOURCE_NOT_CLEAN");
  assertValue(manifest.signing_policy.path, trusted.signingPolicyPath, "SIGNING_POLICY_PATH_MISMATCH");
  assertValue(manifest.signing_policy.identity, FIXED_SIGNING_IDENTITY, "SIGNING_IDENTITY_MISMATCH");
  assertValue(
    manifest.signing_policy.certificate_sha256.toUpperCase(),
    trusted.certificateSHA256.toUpperCase(),
    "SIGNING_CERTIFICATE_POLICY_MISMATCH"
  );
  assertValue(
    manifest.signing_policy.certificate_sha1.toUpperCase(),
    trusted.certificateSHA1.toUpperCase(),
    "SIGNING_CERTIFICATE_SHA1_POLICY_MISMATCH"
  );
  assertValue(manifest.adapter_bundle.bundle_identifier, FIXED_BUNDLE_IDENTIFIER, "BUNDLE_IDENTIFIER_MISMATCH");
  assertValue(manifest.adapter_bundle.source_commit, trusted.sourceCommit, "BUNDLE_SOURCE_COMMIT_MISMATCH");
  assertValue(
    manifest.adapter_bundle.signing_certificate_sha256.toUpperCase(),
    trusted.certificateSHA256.toUpperCase(),
    "BUNDLE_CERTIFICATE_MISMATCH"
  );
  assertSignatureRecord(manifest.adapter_bundle, FIXED_BUNDLE_IDENTIFIER, trusted);
  if (!Array.isArray(manifest.mach_o) || manifest.mach_o.length === 0) {
    throw new Error("MACH_O_CLOSURE_REQUIRED");
  }
  const paths = new Set();
  for (const record of manifest.mach_o) {
    if (paths.has(record.path)) throw new Error(`DUPLICATE_MACH_O_RECORD:${record.path}`);
    paths.add(record.path);
    assertSignatureRecord(record, record.signing_identifier, trusted);
  }
  assertValue(
    manifest.control_utility.path,
    "Contents/MacOS/osrs-explorerctl",
    "CONTROL_UTILITY_NOT_BUNDLED"
  );
  assertValue(
    manifest.control_utility.signing_identifier,
    FIXED_CLI_IDENTIFIER,
    "CONTROL_UTILITY_IDENTIFIER_MISMATCH"
  );
  const cliMachO = manifest.mach_o.find((record) => record.path === manifest.control_utility.path);
  if (!cliMachO) throw new Error("CONTROL_UTILITY_MACH_O_RECORD_MISSING");
  assertValue(cliMachO.sha256, manifest.control_utility.sha256, "CONTROL_UTILITY_DIGEST_MISMATCH");
  assertValue(manifest.node_runtime.path, NODE_RUNTIME_PATH, "NODE_RUNTIME_PATH_MISMATCH");
  const nodeMachO = manifest.mach_o.find((record) => record.path === NODE_RUNTIME_PATH);
  if (!nodeMachO) throw new Error("NODE_RUNTIME_MACH_O_RECORD_MISSING");
  assertValue(nodeMachO.sha256, manifest.node_runtime.sha256, "NODE_RUNTIME_MACH_O_DIGEST_MISMATCH");
  assertToolchainIdentity(manifest.toolchains);
  assertValue(manifest.node_runtime.version, PINNED_RELEASE_TOOLCHAIN.node.version, "BUNDLED_NODE_PIN_MISMATCH");
  assertSHA256(manifest.node_runtime.sha256, "BUNDLED_NODE_DIGEST_INVALID");
  assertValue(
    manifest.node_runtime.source_binary_sha256,
    PINNED_RELEASE_TOOLCHAIN.node.sha256,
    "NODE_SOURCE_BINARY_DIGEST_MISMATCH"
  );
  if (manifest.node_runtime.sha256 === manifest.node_runtime.source_binary_sha256) {
    throw new Error("SIGNED_NODE_DIGEST_NOT_DISTINCT");
  }
  assertValue(
    manifest.node_runtime.source_archive_sha256,
    PINNED_RELEASE_TOOLCHAIN.node.source_archive_sha256,
    "NODE_ARCHIVE_DIGEST_MISMATCH"
  );
  assertValue(
    manifest.worker_dependencies.sharp.version,
    PINNED_RELEASE_TOOLCHAIN.sharp.version,
    "SHARP_VERSION_MISMATCH"
  );
  assertValue(
    manifest.worker_dependencies.libvips.package_name,
    PINNED_RELEASE_TOOLCHAIN.libvips.package_name,
    "LIBVIPS_PACKAGE_NAME_MISMATCH"
  );
  assertValue(
    manifest.worker_dependencies.libvips.version,
    PINNED_RELEASE_TOOLCHAIN.libvips.package_version,
    "LIBVIPS_PACKAGE_VERSION_MISMATCH"
  );
  assertValue(
    manifest.worker_dependencies.libvips.runtime_version,
    PINNED_RELEASE_TOOLCHAIN.libvips.runtime_version,
    "LIBVIPS_RUNTIME_VERSION_MISMATCH"
  );
}

function assertToolchainIdentity(toolchains) {
  for (const name of ["xcode", "swift", "swiftc"]) {
    const expected = PINNED_RELEASE_TOOLCHAIN[name];
    assertValue(toolchains[name].executable, expected.executable, `${name.toUpperCase()}_PATH_MISMATCH`);
    assertValue(toolchains[name].sha256, expected.sha256, `${name.toUpperCase()}_DIGEST_MISMATCH`);
    if (expected.version) {
      assertValue(toolchains[name].version, expected.version, `${name.toUpperCase()}_VERSION_MISMATCH`);
    }
  }
  for (const field of ["version", "sha256", "source_archive_sha256"]) {
    assertValue(
      toolchains.node[field],
      PINNED_RELEASE_TOOLCHAIN.node[field],
      `CONSTRUCTION_NODE_${field.toUpperCase()}_MISMATCH`
    );
  }
  assertValue(toolchains.npm.version, PINNED_RELEASE_TOOLCHAIN.npm.version, "NPM_VERSION_MISMATCH");
  assertValue(toolchains.npm.cli_sha256, PINNED_RELEASE_TOOLCHAIN.npm.cli_sha256, "NPM_CLI_DIGEST_MISMATCH");
}

function assertSignatureRecord(record, expectedIdentifier, trusted) {
  assertValue(record.hardened_runtime, true, `HARDENED_RUNTIME_REQUIRED:${record.path || "bundle"}`);
  assertValue(
    record.signing_certificate_proof,
    "designated-requirement-leaf-sha1",
    `SIGNING_CERTIFICATE_PROOF_MISMATCH:${record.path || "bundle"}`
  );
  assertValue(
    record.signing_certificate_sha256.toUpperCase(),
    trusted.certificateSHA256.toUpperCase(),
    `SIGNATURE_CERTIFICATE_MISMATCH:${record.path || "bundle"}`
  );
  const expectedRequirement =
    `identifier \"${expectedIdentifier}\" and certificate leaf = H\"${trusted.certificateSHA1}\"`;
  assertValue(
    record.designated_requirement.toUpperCase(),
    expectedRequirement.toUpperCase(),
    `DESIGNATED_REQUIREMENT_MISMATCH:${record.path || "bundle"}`
  );
  const expectedEntitlements = record.path === NODE_RUNTIME_PATH ? NODE_RUNTIME_ENTITLEMENTS : {};
  assertValue(
    canonicalJSON(record.entitlements),
    canonicalJSON(expectedEntitlements),
    `ENTITLEMENTS_MISMATCH:${record.path || "bundle"}`
  );
}

function assertSHA256(value, error) {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/i.test(value)) {
    throw new Error(`${error}:observed=${value}`);
  }
}

function canonicalJSON(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function assertValue(observed, expected, error) {
  if (observed !== expected) throw new Error(`${error}:observed=${observed}:expected=${expected}`);
}

export function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

export function combinedProcessOutput(stdout, stderr) {
  return [stdout, stderr]
    .map((value) => String(value).trim())
    .filter(Boolean)
    .join("\n");
}

export function expectedEntitlementsForPath(relativePath) {
  return relativePath === NODE_RUNTIME_PATH ? NODE_RUNTIME_ENTITLEMENTS : NO_ENTITLEMENTS;
}

export function readEffectiveEntitlements(file, expectedEntitlements) {
  const xmlResult = spawnSync(
    "/usr/bin/codesign",
    ["--display", "--entitlements", "-", "--xml", file],
    { encoding: "utf8" }
  );
  const derResult = spawnSync(
    "/usr/bin/codesign",
    ["--display", "--entitlements", "-", "--der", file]
  );
  return effectiveEntitlementsFromCodesignResults(
    file,
    expectedEntitlements,
    xmlResult,
    derResult
  );
}

export function effectiveEntitlementsFromCodesignResults(
  file,
  expectedEntitlements,
  xmlResult,
  derResult
) {
  assertCodesignEntitlementsResult(file, "XML", xmlResult);
  assertCodesignEntitlementsResult(file, "DER", derResult);

  const expected = canonicalJSON(expectedEntitlements);
  const expectsEntitlements = expected !== "{}";
  const plist = String(xmlResult.stdout).trim();
  const der = Buffer.isBuffer(derResult.stdout)
    ? derResult.stdout
    : Buffer.from(derResult.stdout || "", "binary");

  if (!expectsEntitlements) {
    if (plist || der.length !== 0) {
      throw new Error(`UNEXPECTED_EFFECTIVE_ENTITLEMENTS:${file}`);
    }
    return {};
  }
  if (!plist) throw new Error(`EFFECTIVE_ENTITLEMENTS_PLIST_MISSING:${file}`);
  if (der.length === 0) throw new Error(`EFFECTIVE_ENTITLEMENTS_DER_MISSING:${file}`);

  const xmlEntitlements = parseEntitlementsPlist(plist);
  assertValue(
    canonicalJSON(xmlEntitlements),
    expected,
    `EFFECTIVE_ENTITLEMENTS_XML_MISMATCH:${file}`
  );
  const derEntitlements = parseEntitlementsDER(der);
  assertValue(
    canonicalJSON(derEntitlements),
    expected,
    `EFFECTIVE_ENTITLEMENTS_DER_MISMATCH:${file}`
  );
  return xmlEntitlements;
}

export function parseEntitlementsPlist(value) {
  const plist = String(value).trim();
  if (!plist) throw new Error("ENTITLEMENTS_PLIST_MISSING");
  const result = spawnSync(
    "/usr/bin/plutil",
    ["-convert", "json", "-o", "-", "--", "-"],
    { encoding: "utf8", input: plist }
  );
  if (result.status !== 0) {
    throw new Error(`ENTITLEMENTS_PLIST_INVALID:${String(result.stderr).trim()}`);
  }
  const parsed = JSON.parse(result.stdout);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("ENTITLEMENTS_DICTIONARY_REQUIRED");
  }
  return parsed;
}

function assertCodesignEntitlementsResult(file, format, result) {
  const stderr = String(result.stderr || "").trim();
  if (result.status !== 0) {
    throw new Error(`ENTITLEMENTS_${format}_READ_FAILED:${file}:${result.status}:${stderr}`);
  }
  const warning = stderr.split(/\r?\n/).find((line) => /^\s*warning:/i.test(line));
  if (warning) throw new Error(`ENTITLEMENTS_${format}_READ_WARNING:${file}:${warning.trim()}`);
}

function parseEntitlementsDER(value) {
  const der = Buffer.from(value);
  const root = readDERElement(der, 0, der.length);
  if (root.tag !== 0x70 || root.end !== der.length) {
    throw new Error("ENTITLEMENTS_DER_DICTIONARY_REQUIRED");
  }

  const version = readDERElement(der, root.contentStart, root.end);
  if (version.tag !== 0x02 || !version.content.equals(Buffer.from([0x01]))) {
    throw new Error("ENTITLEMENTS_DER_VERSION_UNSUPPORTED");
  }
  const dictionary = readDERElement(der, version.end, root.end);
  if (dictionary.tag !== 0xb0 || dictionary.end !== root.end) {
    throw new Error("ENTITLEMENTS_DER_DICTIONARY_REQUIRED");
  }

  const entitlements = Object.create(null);
  let offset = dictionary.contentStart;
  while (offset < dictionary.end) {
    const entry = readDERElement(der, offset, dictionary.end);
    if (entry.tag !== 0x30) throw new Error("ENTITLEMENTS_DER_ENTRY_INVALID");
    const key = readDERElement(der, entry.contentStart, entry.end);
    if (key.tag !== 0x0c) throw new Error("ENTITLEMENTS_DER_KEY_INVALID");
    const name = new TextDecoder("utf-8", { fatal: true }).decode(key.content);
    if (!name || Object.hasOwn(entitlements, name)) {
      throw new Error("ENTITLEMENTS_DER_KEY_INVALID");
    }
    const entitlementValue = readDERElement(der, key.end, entry.end);
    if (
      entitlementValue.tag !== 0x01
      || entitlementValue.content.length !== 1
      || entitlementValue.end !== entry.end
      || ![0x00, 0xff].includes(entitlementValue.content[0])
    ) {
      throw new Error(`ENTITLEMENTS_DER_BOOLEAN_REQUIRED:${name}`);
    }
    entitlements[name] = entitlementValue.content[0] === 0xff;
    offset = entry.end;
  }
  return entitlements;
}

function readDERElement(der, offset, limit) {
  if (offset + 2 > limit) throw new Error("ENTITLEMENTS_DER_TRUNCATED");
  const tag = der[offset];
  const firstLength = der[offset + 1];
  let contentLength;
  let contentStart;
  if (firstLength < 0x80) {
    contentLength = firstLength;
    contentStart = offset + 2;
  } else {
    const lengthBytes = firstLength & 0x7f;
    if (lengthBytes === 0 || lengthBytes > 4 || offset + 2 + lengthBytes > limit) {
      throw new Error("ENTITLEMENTS_DER_LENGTH_INVALID");
    }
    if (der[offset + 2] === 0) throw new Error("ENTITLEMENTS_DER_LENGTH_INVALID");
    contentLength = 0;
    for (let index = 0; index < lengthBytes; index += 1) {
      contentLength = (contentLength * 0x100) + der[offset + 2 + index];
    }
    if (contentLength < 0x80) throw new Error("ENTITLEMENTS_DER_LENGTH_INVALID");
    contentStart = offset + 2 + lengthBytes;
  }
  const end = contentStart + contentLength;
  if (end > limit) throw new Error("ENTITLEMENTS_DER_TRUNCATED");
  return {
    tag,
    contentStart,
    content: der.subarray(contentStart, end),
    end
  };
}
