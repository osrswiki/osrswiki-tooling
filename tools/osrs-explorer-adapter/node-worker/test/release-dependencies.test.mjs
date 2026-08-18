import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import {
  FIXED_BUNDLE_IDENTIFIER,
  FIXED_CLI_IDENTIFIER,
  FIXED_SIGNING_IDENTITY,
  NODE_RUNTIME_ENTITLEMENTS,
  NODE_RUNTIME_PATH,
  PINNED_RELEASE_TOOLCHAIN,
  combinedProcessOutput,
  effectiveEntitlementsFromCodesignResults,
  parseEntitlementsPlist,
  sha256,
  validateTrustedReleaseManifest
} from "../../scripts/release-verification.mjs";

const workerRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const nodeRuntimeEntitlementsDER = Buffer.from(
  "7062020101b05d30240c1f636f6d2e6170706c652e73656375726974792e63732e616c6c6f772d6a69740101ff30350c30636f6d2e6170706c652e73656375726974792e63732e64697361626c652d6c6962726172792d76616c69646174696f6e0101ff",
  "hex"
);

test("codesign display output retains fields split across stdout and stderr", () => {
  assert.equal(
    combinedProcessOutput(
      'designated => identifier "adapter" and certificate leaf = H"abc"\n',
      "Identifier=adapter\nAuthority=Local Signing\n"
    ),
    'designated => identifier "adapter" and certificate leaf = H"abc"\nIdentifier=adapter\nAuthority=Local Signing'
  );
});

test("Node runtime entitlements are exact and exclude broader executable-memory access", () => {
  const entitlementsPath = path.resolve(workerRoot, "../Resources/NodeRuntime.entitlements");
  const result = spawnSync(
    "/usr/bin/plutil",
    ["-convert", "xml1", "-o", "-", "--", entitlementsPath],
    { encoding: "utf8" }
  );
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(parseEntitlementsPlist(result.stdout), NODE_RUNTIME_ENTITLEMENTS);
  assert.doesNotMatch(result.stdout, /allow-unsigned-executable-memory/);
});

test("effective Node entitlement reads require warning-free exact XML and DER", () => {
  const file = `/candidate/${NODE_RUNTIME_PATH}`;
  const xml = entitlementsPlist(NODE_RUNTIME_ENTITLEMENTS);
  const validXML = codesignResult(xml);
  const validDER = codesignResult(nodeRuntimeEntitlementsDER);
  assert.deepEqual(
    effectiveEntitlementsFromCodesignResults(
      file,
      NODE_RUNTIME_ENTITLEMENTS,
      validXML,
      validDER
    ),
    NODE_RUNTIME_ENTITLEMENTS
  );

  assert.throws(
    () => effectiveEntitlementsFromCodesignResults(
      file,
      NODE_RUNTIME_ENTITLEMENTS,
      codesignResult(xml, "warning: binary contains an invalid entitlements blob. The OS will ignore these entitlements."),
      validDER
    ),
    /ENTITLEMENTS_XML_READ_WARNING.*invalid entitlements blob/
  );
  assert.throws(
    () => effectiveEntitlementsFromCodesignResults(
      file,
      NODE_RUNTIME_ENTITLEMENTS,
      codesignResult(""),
      validDER
    ),
    /EFFECTIVE_ENTITLEMENTS_PLIST_MISSING/
  );
  assert.throws(
    () => effectiveEntitlementsFromCodesignResults(
      file,
      NODE_RUNTIME_ENTITLEMENTS,
      codesignResult("<plist><dict>"),
      validDER
    ),
    /ENTITLEMENTS_PLIST_INVALID/
  );

  for (const entitlements of [
    { "com.apple.security.cs.allow-jit": true },
    {
      "com.apple.security.cs.allow-jit": false,
      "com.apple.security.cs.disable-library-validation": true
    },
    {
      ...NODE_RUNTIME_ENTITLEMENTS,
      "com.apple.security.cs.allow-unsigned-executable-memory": true
    }
  ]) {
    assert.throws(
      () => effectiveEntitlementsFromCodesignResults(
        file,
        NODE_RUNTIME_ENTITLEMENTS,
        codesignResult(entitlementsPlist(entitlements)),
        validDER
      ),
      /EFFECTIVE_ENTITLEMENTS_XML_MISMATCH/
    );
  }
});

test("effective Node entitlement reads validate DER and reject entitlements elsewhere", () => {
  const file = `/candidate/${NODE_RUNTIME_PATH}`;
  const validXML = codesignResult(entitlementsPlist(NODE_RUNTIME_ENTITLEMENTS));
  assert.throws(
    () => effectiveEntitlementsFromCodesignResults(
      file,
      NODE_RUNTIME_ENTITLEMENTS,
      validXML,
      codesignResult(Buffer.alloc(0))
    ),
    /EFFECTIVE_ENTITLEMENTS_DER_MISSING/
  );
  assert.throws(
    () => effectiveEntitlementsFromCodesignResults(
      file,
      NODE_RUNTIME_ENTITLEMENTS,
      validXML,
      codesignResult(Buffer.from("deadbeef", "hex"))
    ),
    /ENTITLEMENTS_DER_(?:DICTIONARY_REQUIRED|LENGTH_INVALID|TRUNCATED)/
  );
  const mismatchedDER = Buffer.from(nodeRuntimeEntitlementsDER);
  mismatchedDER[mismatchedDER.length - 1] = 0x00;
  assert.throws(
    () => effectiveEntitlementsFromCodesignResults(
      file,
      NODE_RUNTIME_ENTITLEMENTS,
      validXML,
      codesignResult(mismatchedDER)
    ),
    /EFFECTIVE_ENTITLEMENTS_DER_MISMATCH/
  );
  assert.throws(
    () => effectiveEntitlementsFromCodesignResults(
      file,
      NODE_RUNTIME_ENTITLEMENTS,
      validXML,
      codesignResult(
        nodeRuntimeEntitlementsDER,
        "warning: binary contains an invalid DER entitlements blob."
      )
    ),
    /ENTITLEMENTS_DER_READ_WARNING/
  );

  assert.deepEqual(
    effectiveEntitlementsFromCodesignResults(
      "/candidate/non-node",
      {},
      codesignResult(""),
      codesignResult(Buffer.alloc(0))
    ),
    {}
  );
  assert.throws(
    () => effectiveEntitlementsFromCodesignResults(
      "/candidate/non-node",
      {},
      validXML,
      codesignResult(nodeRuntimeEntitlementsDER)
    ),
    /UNEXPECTED_EFFECTIVE_ENTITLEMENTS/
  );
});

test("effective Node entitlement reads reject prototype-related DER keys and duplicates", () => {
  const file = `/candidate/${NODE_RUNTIME_PATH}`;
  const validXML = codesignResult(entitlementsPlist(NODE_RUNTIME_ENTITLEMENTS));
  const expectedEntries = Object.entries(NODE_RUNTIME_ENTITLEMENTS);

  for (const name of ["__proto__", "constructor", "prototype"]) {
    const der = entitlementsDER([...expectedEntries, [name, true]]);
    if (name === "__proto__") {
      assert.equal(
        der.subarray(-16).toString("hex"),
        "300e0c095f5f70726f746f5f5f0101ff"
      );
    }
    assert.throws(
      () => effectiveEntitlementsFromCodesignResults(
        file,
        NODE_RUNTIME_ENTITLEMENTS,
        validXML,
        codesignResult(der)
      ),
      /EFFECTIVE_ENTITLEMENTS_DER_MISMATCH/,
      name
    );
  }

  for (const name of ["__proto__", "constructor", "prototype"]) {
    assert.throws(
      () => effectiveEntitlementsFromCodesignResults(
        file,
        NODE_RUNTIME_ENTITLEMENTS,
        validXML,
        codesignResult(entitlementsDER([[name, true], [name, false]]))
      ),
      /ENTITLEMENTS_DER_KEY_INVALID/,
      `duplicate ${name}`
    );
  }
});

test("Node signing selects the action first and explicitly generates XML and DER slots", () => {
  const build = fs.readFileSync(path.resolve(workerRoot, "../scripts/build-apps.sh"), "utf8");
  const signingBlock = build.match(
    /typeset -a signing_arguments[\s\S]+?\/usr\/bin\/codesign "\$\{signing_arguments\[@\]\}" "\$candidate"/
  )?.[0];
  assert.ok(signingBlock, "nested signing block missing");
  assert.match(
    signingBlock,
    /signing_arguments=\(\s*--sign "\$signing_identity"\s*--force --options runtime --timestamp=none/
  );
  assert.match(
    signingBlock,
    /signing_arguments\+=\(--generate-entitlement-der --entitlements "\$node_entitlements"\)/
  );
});

test("release closure contains one patched Sharp and the expected libvips", () => {
  const packageManifest = JSON.parse(fs.readFileSync(path.join(workerRoot, "package.json"), "utf8"));
  const lock = JSON.parse(fs.readFileSync(path.join(workerRoot, "package-lock.json"), "utf8"));
  const sharpPackagePaths = Object.keys(lock.packages).filter(
    (entry) => entry === "node_modules/sharp" || entry.endsWith("/node_modules/sharp")
  );

  assert.equal(packageManifest.dependencies.sharp, "0.35.3");
  assert.deepEqual(sharpPackagePaths, ["node_modules/sharp"]);
  assert.equal(lock.packages["node_modules/sharp"].version, "0.35.3");
  assert.equal(
    lock.packages["node_modules/@img/sharp-libvips-darwin-arm64"].version,
    "1.3.2"
  );
  const liveLibvipsPackage = JSON.parse(fs.readFileSync(
    path.join(workerRoot, "node_modules/@img/sharp-libvips-darwin-arm64/package.json"),
    "utf8"
  ));
  assert.equal(liveLibvipsPackage.name, "@img/sharp-libvips-darwin-arm64");
  assert.equal(liveLibvipsPackage.version, "1.3.2");
  assert.equal(sharp.versions.sharp, "0.35.3");
  assert.equal(sharp.versions.vips, "8.18.3");
});

test("release verification rejects untrusted roots, commits, signing, identifiers, and runtimes", () => {
  const trusted = {
    sourceRoot: "/trusted/source",
    sourceCommit: "1".repeat(40),
    signingPolicyPath: "/trusted/signing-policy.json",
    certificateSHA256: "A".repeat(64),
    certificateSHA1: "B".repeat(40)
  };
  const base = releaseManifest(trusted);
  assert.doesNotThrow(() => validateTrustedReleaseManifest(base, trusted));

  for (const [name, mutate, expression] of [
    ["source root", (value) => { value.source.root = "/hostile/source"; }, /TRUSTED_SOURCE_ROOT_MISMATCH/],
    ["source commit", (value) => { value.source.git_head = "2".repeat(40); }, /TRUSTED_SOURCE_COMMIT_MISMATCH/],
    ["dirty source", (value) => { value.source.git_status_sha256 = sha256(Buffer.from(" M source")); }, /SOURCE_NOT_CLEAN/],
    ["signing policy", (value) => { value.signing_policy.path = "/hostile/policy"; }, /SIGNING_POLICY_PATH_MISMATCH/],
    ["bundle id", (value) => { value.adapter_bundle.bundle_identifier = "hostile.bundle"; }, /BUNDLE_IDENTIFIER_MISMATCH/],
    ["certificate", (value) => { value.adapter_bundle.signing_certificate_sha256 = "C".repeat(64); }, /BUNDLE_CERTIFICATE_MISMATCH/],
    ["app hardened runtime", (value) => { value.adapter_bundle.hardened_runtime = false; }, /HARDENED_RUNTIME_REQUIRED/],
    ["app entitlement", (value) => { value.adapter_bundle.entitlements = { "com.apple.security.cs.allow-jit": true }; }, /ENTITLEMENTS_MISMATCH/],
    ["nested hardened runtime", (value) => { value.mach_o[0].hardened_runtime = false; }, /HARDENED_RUNTIME_REQUIRED/],
    ["non-Node entitlement", (value) => { value.mach_o[0].entitlements = { "com.apple.security.cs.allow-jit": true }; }, /ENTITLEMENTS_MISMATCH/],
    ["missing Node JIT entitlement", (value) => { delete value.mach_o[1].entitlements["com.apple.security.cs.allow-jit"]; }, /ENTITLEMENTS_MISMATCH/],
    ["missing Node library-validation entitlement", (value) => { delete value.mach_o[1].entitlements["com.apple.security.cs.disable-library-validation"]; }, /ENTITLEMENTS_MISMATCH/],
    ["broader Node entitlement", (value) => { value.mach_o[1].entitlements["com.apple.security.cs.allow-unsigned-executable-memory"] = true; }, /ENTITLEMENTS_MISMATCH/],
    ["nested requirement", (value) => { value.mach_o[0].designated_requirement = "identifier \"hostile\""; }, /DESIGNATED_REQUIREMENT_MISMATCH/],
    ["certificate proof", (value) => { value.mach_o[0].signing_certificate_proof = "embedded-chain"; }, /SIGNING_CERTIFICATE_PROOF_MISMATCH/],
    ["external cli", (value) => { value.control_utility.path = "../osrs-explorerctl"; }, /CONTROL_UTILITY_NOT_BUNDLED/],
    ["swift digest", (value) => { value.toolchains.swift.sha256 = "hostile"; }, /SWIFT_DIGEST_MISMATCH/],
    ["node digest", (value) => { value.toolchains.node.sha256 = "hostile"; }, /CONSTRUCTION_NODE_SHA256_MISMATCH/],
    ["Node source digest", (value) => { value.node_runtime.source_binary_sha256 = "hostile"; }, /NODE_SOURCE_BINARY_DIGEST_MISMATCH/],
    ["signed Node digest conflation", (value) => { value.node_runtime.sha256 = value.node_runtime.source_binary_sha256; value.mach_o[1].sha256 = value.node_runtime.sha256; }, /SIGNED_NODE_DIGEST_NOT_DISTINCT/],
    ["signed Node Mach-O digest", (value) => { value.mach_o[1].sha256 = "D".repeat(64); }, /NODE_RUNTIME_MACH_O_DIGEST_MISMATCH/],
    ["npm version", (value) => { value.toolchains.npm.version = "current"; }, /NPM_VERSION_MISMATCH/],
    ["libvips package", (value) => { value.worker_dependencies.libvips.version = "current"; }, /LIBVIPS_PACKAGE_VERSION_MISMATCH/],
    ["libvips runtime", (value) => { value.worker_dependencies.libvips.runtime_version = "current"; }, /LIBVIPS_RUNTIME_VERSION_MISMATCH/]
  ]) {
    const candidate = structuredClone(base);
    mutate(candidate);
    assert.throws(
      () => validateTrustedReleaseManifest(candidate, trusted),
      expression,
      name
    );
  }
});

test("pinned release tools ignore a hostile caller PATH", () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "osrs-release-toolchain-"));
  const hostileEnvironment = {
    HOME: os.homedir(),
    TMPDIR: os.tmpdir(),
    PATH: path.join(temporary, "hostile-bin")
  };
  const sanitizedBuildEnvironment = {
    HOME: os.homedir(),
    TMPDIR: os.tmpdir(),
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin"
  };
  try {
    const archive = path.join(
      os.homedir(),
      "Developer/osrswiki-local-artifacts/cache/node-v26.4.0-darwin-arm64.tar.xz"
    );
    assert.equal(sha256(fs.readFileSync(archive)), PINNED_RELEASE_TOOLCHAIN.node.source_archive_sha256);
    const extraction = spawnSync(
      "/usr/bin/tar",
      ["-xJf", archive, "-C", temporary],
      { env: hostileEnvironment, encoding: "utf8" }
    );
    assert.equal(extraction.status, 0, extraction.stderr);
    const node = path.join(temporary, "node-v26.4.0-darwin-arm64/bin/node");
    const npmCLI = path.join(
      temporary,
      "node-v26.4.0-darwin-arm64/lib/node_modules/npm/bin/npm-cli.js"
    );
    assert.equal(sha256(fs.readFileSync(node)), PINNED_RELEASE_TOOLCHAIN.node.sha256);
    assert.equal(sha256(fs.readFileSync(npmCLI)), PINNED_RELEASE_TOOLCHAIN.npm.cli_sha256);
    assert.equal(command(node, ["--version"], hostileEnvironment), PINNED_RELEASE_TOOLCHAIN.node.version);
    assert.equal(
      command(node, ["-p", "require(process.argv[1]).version", path.resolve(npmCLI, "../..", "package.json")], hostileEnvironment),
      PINNED_RELEASE_TOOLCHAIN.npm.version
    );
    assert.equal(
      command(PINNED_RELEASE_TOOLCHAIN.swift.executable, ["--version"], sanitizedBuildEnvironment)
        .replace(/^swift-driver version: 1\.148\.6 /, "")
        .replaceAll("\n", " | "),
      PINNED_RELEASE_TOOLCHAIN.swift.version
    );
    assert.equal(
      sha256(fs.readFileSync(PINNED_RELEASE_TOOLCHAIN.swift.executable)),
      PINNED_RELEASE_TOOLCHAIN.swift.sha256
    );
    assert.equal(
      command(PINNED_RELEASE_TOOLCHAIN.xcode.executable, ["-version"], sanitizedBuildEnvironment).replaceAll("\n", " | "),
      PINNED_RELEASE_TOOLCHAIN.xcode.version
    );
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

test("privileged release entry points suppress hostile zsh startup files", () => {
  const scriptsRoot = path.resolve(workerRoot, "../scripts");
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "osrs-hostile-zdotdir-"));
  const marker = path.join(temporary, "startup-executed");
  fs.writeFileSync(
    path.join(temporary, ".zshenv"),
    `print -r -- ZDOTDIR_STARTUP_EXECUTED > ${JSON.stringify(marker)}\n`,
    { mode: 0o600 }
  );
  const environment = { ...process.env, ZDOTDIR: temporary };
  try {
    for (const name of ["build-apps.sh", "install-local.sh"]) {
      const script = path.join(scriptsRoot, name);
      assert.equal(fs.readFileSync(script, "utf8").split("\n", 1)[0], "#!/bin/zsh -f");
      const result = spawnSync(script, [], { env: environment, encoding: "utf8" });
      assert.equal(result.status, 64, result.stderr || result.stdout);
      assert.equal(fs.existsSync(marker), false, name);
    }

    const signing = path.join(scriptsRoot, "create-local-signing-identity.sh");
    assert.equal(fs.readFileSync(signing, "utf8").split("\n", 1)[0], "#!/bin/zsh -f");
    const signingResult = spawnSync(
      signing,
      ["--probe-startup-sanitization"],
      { env: environment, encoding: "utf8" }
    );
    assert.equal(signingResult.status, 0, signingResult.stderr || signingResult.stdout);
    assert.equal(signingResult.stdout.trim(), "SHELL_STARTUP_SANITIZED");
    assert.equal(fs.existsSync(marker), false, "create-local-signing-identity.sh");
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});

test("signing identity script imports a verified non-extractable PKCS8 DER key", () => {
  const script = fs.readFileSync(
    path.resolve(workerRoot, "../scripts/create-local-signing-identity.sh"),
    "utf8"
  );
  assert.match(script, /pkcs8 -topk8/);
  assert.match(script, /-v1 PBE-SHA1-3DES/);
  assert.match(script, /-outform DER/);
  assert.match(script, /"\$security_tool" import[\s\S]*\n\s*-x/);
  assert.match(script, /"\$security_tool" import[\s\S]*\n\s*-f pkcs8[\s\S]*\n\s*-t priv/);
  assert.match(script, /"\$security_tool" import[\s\S]*\n\s*-f pemseq[\s\S]*\n\s*-t cert/);
  assert.match(script, /certificate_sha256=.*[\s\S]*certificate_mutation_attempted=true[\s\S]*import/);
  assert.match(script, /private_key_mutation_attempted=true[\s\S]*import/);
  assert.match(script, /trust_mutation_attempted=true[\s\S]*add-trusted-cert/);
  assert.match(script, /delete-identity -Z "\$certificate_sha256" -t/);
  assert.match(script, /delete-certificate -Z "\$certificate_sha256" -t/);
  assert.match(script, /SIGNING_IDENTITY_LOOKUP_FAILED/);
  assert.match(script, /ROLLBACK_FAILED/);
  assert.match(script, /policy_root_created[\s\S]*rmdir "\$policy_root"/);
  assert.match(script, /mktemp -d "\$policy_root\/\.signing-policy\.XXXXXX"/);
  assert.match(script, /policy_property_list="\$policy_staging_directory\/signing-policy\.plist"/);
  assert.match(script, /policy_temporary="\$policy_staging_directory\/signing-policy\.json"/);
  assert.match(script, /plutil -convert json -o "\$policy_temporary" "\$policy_property_list"/);
  assert.match(script, /rmdir "\$policy_staging_directory"/);
  assert.match(script, /policy_inode[\s\S]*policy_publish_attempted[\s\S]*\/bin\/ln/);
  assert.match(script, /add-trusted-cert[\s\S]*-p codeSign/);
  assert.match(script, /add-trusted-cert[\s\S]*-r trustRoot/);
  assert.doesNotMatch(script, /trustAsRoot/);
  assert.match(script, /verify-cert[\s\S]*-p codeSign[\s\S]*-R offline/);
  assert.match(script, /find-key -l "\$identity"[\s\S]*-t private -s/);
  assert.match(script, /SIGNING_IDENTITY_INTERRUPTED:INT/);
  assert.match(script, /trap - EXIT HUP INT TERM/);
  assert.match(script, /command_supervisor[\s\S]*300[\s\S]*add-trusted-cert/);
  assert.match(script, /alarm shift @ARGV; exec @ARGV[\s\S]*codesign --force/);
  assert.doesNotMatch(script, /pkcs12/i);
  assert.match(script, /rsa:3072/);
  assert.match(script, /-sha256/);
  assert.match(script, /Public-Key: \(3072 bit\)/);
  assert.match(script, /Signature Algorithm: sha256WithRSAEncryption/);
  assert.match(script, /SSL client : No/);
  assert.match(script, /SSL server : No/);
  assert.match(script, /extendedKeyUsage = critical,codeSigning/);
  assert.doesNotMatch(script, /dump-keychain/);
  assert.doesNotMatch(script, /find-identity/);
  assert.match(script, /IMPORTED_CERTIFICATE_FINGERPRINT_MISMATCH/);
  assert.match(script, /codesign --force --sign "\$certificate_sha1"/);

  const policyRoot = fs.mkdtempSync(path.join(os.tmpdir(), "osrs-signing-policy-"));
  const propertyListPath = path.join(policyRoot, "signing-policy.plist");
  const policyPath = path.join(policyRoot, "signing-policy.json");
  try {
    const create = spawnSync("/usr/bin/plutil", ["-create", "xml1", propertyListPath], {
      encoding: "utf8"
    });
    assert.equal(create.status, 0, create.stderr || create.stdout);
    const insert = spawnSync(
      "/usr/bin/plutil",
      ["-insert", "schema_version", "-integer", "1", propertyListPath],
      { encoding: "utf8" }
    );
    assert.equal(insert.status, 0, insert.stderr || insert.stdout);
    const convert = spawnSync(
      "/usr/bin/plutil",
      ["-convert", "json", "-o", policyPath, propertyListPath],
      { encoding: "utf8" }
    );
    assert.equal(convert.status, 0, convert.stderr || convert.stdout);
    assert.deepEqual(JSON.parse(fs.readFileSync(policyPath, "utf8")), {
      schema_version: 1
    });
  } finally {
    fs.rmSync(policyRoot, { recursive: true, force: true });
  }

  const probe = fs.readFileSync(
    path.resolve(workerRoot, "../scripts/verify-nonextractable-signing-import.sh"),
    "utf8"
  );
  assert.match(probe, /0x00000010 <uint32>=0x00000000/);
  assert.match(probe, /0x00000011 <uint32>=0x00000001/);
  assert.match(probe, /PROBE_CODESIGN_ACL_NOT_EXCLUSIVE/);
  assert.match(probe, /cleanup[\s\S]*return "\$exit_code"/);
});

test(
  "disposable keychain verifies the exact non-extractable signing import",
  { skip: process.env.OSRS_RUN_DISPOSABLE_KEYCHAIN_TEST !== "1" },
  () => {
    const script = path.resolve(
      workerRoot,
      "../scripts/verify-nonextractable-signing-import.sh"
    );
    const result = spawnSync(script, [], {
      env: { ...process.env, TMPDIR: os.tmpdir() },
      encoding: "utf8"
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.deepEqual(JSON.parse(result.stdout), {
      status: "NONEXTRACTABLE_SIGNING_IMPORT_VERIFIED",
      explicit_format: "pkcs8-der",
      rsa_bits: 3072,
      certificate_signature: "sha256WithRSAEncryption",
      private_key_encryption: "PBE-SHA1-3DES",
      iterations: 2048,
      private_key_extractable: false,
      private_key_never_extractable: true,
      identity_pair_verified: true,
      allowed_application: "/usr/bin/codesign",
      codesign_verification: "deferred_until_code-sign-only-trust",
      ssl_client: false,
      ssl_server: false,
      user_keychain_search_list_unchanged: true
    });
  }
);

test("disposable signing probe cleans up a keychain-creation failure", () => {
  const script = path.resolve(
    workerRoot,
    "../scripts/verify-nonextractable-signing-import.sh"
  );
  const prefix = "osrs-adapter-signing-import-probe.";
  const rootsBefore = fs.readdirSync(os.tmpdir())
    .filter((name) => name.startsWith(prefix))
    .sort();
  const result = spawnSync(script, ["--probe-keychain-create-failure"], {
    env: { ...process.env, TMPDIR: os.tmpdir() },
    encoding: "utf8"
  });
  const rootsAfter = fs.readdirSync(os.tmpdir())
    .filter((name) => name.startsWith(prefix))
    .sort();
  assert.equal(result.status, 206, result.stderr || result.stdout);
  assert.match(result.stderr, /PROBE_INJECTED_KEYCHAIN_CREATE_FAILURE/);
  assert.deepEqual(rootsAfter, rootsBefore);
});

test("production signing rollback removes fingerprint-bound partial import effects", () => {
  const probe = runProductionRollbackProbe("partial-import");
  try {
    assert.equal(probe.result.status, 71, probe.result.stderr || probe.result.stdout);
    assert.match(probe.result.stderr, /PRIVATE_KEY_IMPORT_FAILED/);
    assert.doesNotMatch(probe.result.stderr, /ROLLBACK_FAILED/);
    assert.deepEqual(fs.readdirSync(probe.stateRoot).sort(), ["commands.log"]);
    const commands = fs.readFileSync(path.join(probe.stateRoot, "commands.log"), "utf8");
    assert.match(commands, /delete-identity -Z [0-9A-F]{64} -t /);
    assert.doesNotMatch(commands, /delete-identity .* -c /);
    assert.equal(fs.existsSync(path.join(probe.home, "Library/Application Support/OSRS Explorer Adapter")), false);
  } finally {
    fs.rmSync(probe.root, { recursive: true, force: true });
  }
});

test("production signing rollback surfaces cleanup failure", () => {
  const probe = runProductionRollbackProbe("cleanup-failure");
  try {
    assert.equal(probe.result.status, 70, probe.result.stderr || probe.result.stdout);
    assert.match(probe.result.stderr, /PRIVATE_KEY_IMPORT_FAILED/);
    assert.match(probe.result.stderr, /ROLLBACK_FAILED/);
    assert.equal(fs.existsSync(path.join(probe.stateRoot, "certificate.pem")), true);
    assert.equal(fs.existsSync(path.join(probe.stateRoot, "private-key")), true);
  } finally {
    fs.rmSync(probe.root, { recursive: true, force: true });
  }
});

test("production signing preflight distinguishes lookup errors from absence", () => {
  const probe = runProductionRollbackProbe("lookup-failure");
  try {
    assert.equal(probe.result.status, 72, probe.result.stderr || probe.result.stdout);
    assert.match(probe.result.stderr, /SIGNING_IDENTITY_LOOKUP_FAILED:72/);
    const commands = fs.readFileSync(path.join(probe.stateRoot, "commands.log"), "utf8");
    assert.doesNotMatch(commands, /^import /m);
  } finally {
    fs.rmSync(probe.root, { recursive: true, force: true });
  }
});

test("production signing accepts macOS success-with-empty-output as exact-name absence", () => {
  const probe = runProductionRollbackProbe("empty-absence");
  try {
    assert.equal(probe.result.status, 71, probe.result.stderr || probe.result.stdout);
    assert.match(probe.result.stderr, /PRIVATE_KEY_IMPORT_FAILED/);
    assert.doesNotMatch(probe.result.stderr, /SIGNING_IDENTITY_ALREADY_EXISTS/);
    assert.doesNotMatch(probe.result.stderr, /ROLLBACK_FAILED/);
    assert.deepEqual(fs.readdirSync(probe.stateRoot).sort(), ["commands.log"]);
  } finally {
    fs.rmSync(probe.root, { recursive: true, force: true });
  }
});

test("production signing cleanup trusts exact postconditions after nonzero deletion", () => {
  const probe = runProductionRollbackProbe("trust-failure-cleanup-nonzero");
  try {
    assert.equal(probe.result.status, 73, probe.result.stderr || probe.result.stdout);
    assert.match(probe.result.stderr, /CODE_SIGN_TRUST_INSTALL_FAILED/);
    assert.doesNotMatch(probe.result.stderr, /ROLLBACK_FAILED/);
    assert.deepEqual(fs.readdirSync(probe.stateRoot).sort(), ["commands.log"]);
    const commands = fs.readFileSync(path.join(probe.stateRoot, "commands.log"), "utf8");
    assert.match(commands, /add-trusted-cert -r trustRoot -p codeSign /);
    assert.match(commands, /find-key -l OSRS Explorer Adapter Local Signing -t private -s /);
    assert.match(commands, /verify-cert -c .* -p codeSign -L -R offline/);
  } finally {
    fs.rmSync(probe.root, { recursive: true, force: true });
  }
});

test("production signing reaps a blocked trust process before signal rollback", async (context) => {
  for (const [signal, status] of [["SIGHUP", 129], ["SIGINT", 130], ["SIGTERM", 143]]) {
    await context.test(signal, async () => {
      const probe = prepareProductionRollbackProbe("block-during-trust");
      let child;
      let retained;
      try {
        child = spawnInOwnProcessGroup(probe.script, probe.args, {
          env: probe.env,
          stdio: ["ignore", "pipe", "pipe"]
        });
        const observed = observeChild(child);
        await waitForPath(path.join(probe.stateRoot, "trust-pgid"), 10_000);
        retained = startRetainedGroupMember(
          probe.root,
          path.join(probe.stateRoot, "trust-pgid"),
          probe.stateRoot
        );
        await waitForPath(retained.readyPath, 10_000);
        await waitForPath(path.join(probe.stateRoot, "trust-ready"), 10_000);
        process.kill(-child.pid, signal);
        await delay(5_750);
        assertRetainedGroupMember(retained, path.join(probe.stateRoot, "trust-pgid"));
        assert.equal(child.exitCode, null, "signing caller returned before retained group absence");
        assert.equal(child.signalCode, null, "signing caller was signaled before retained group absence");
        assert.doesNotMatch(
          fs.readFileSync(path.join(probe.stateRoot, "commands.log"), "utf8"),
          /delete-identity|delete-certificate/,
          "rollback began while the trust group still existed"
        );
        await releaseRetainedGroupMember(retained);
        const result = await observed.result;
        assert.equal(result.status, status, result.stderr || result.stdout);
        assert.equal(result.signal, null, result.stderr || result.stdout);
        assert.match(result.stderr, new RegExp(`SIGNING_IDENTITY_INTERRUPTED:${signal.slice(3)}`));
        assert.doesNotMatch(result.stderr, /ROLLBACK_FAILED/);
        assert.equal(fs.existsSync(path.join(probe.stateRoot, "rollback-raced")), false);
        const trustProcessGroup = Number.parseInt(
          fs.readFileSync(path.join(probe.stateRoot, "trust-pgid"), "utf8"),
          10
        );
        assert.throws(() => process.kill(-trustProcessGroup, 0), { code: "ESRCH" });
        removeRetainedGroupMarkers(retained);
        assert.deepEqual(fs.readdirSync(probe.stateRoot).sort(), [
          "commands.log",
          "trust-pgid",
          "trust-ready"
        ]);
        assert.equal(
          fs.existsSync(path.join(probe.home, "Library/Application Support/OSRS Explorer Adapter")),
          false
        );
        assert.throws(() => process.kill(-child.pid, 0), { code: "ESRCH" });
      } finally {
        const trustGroupPath = path.join(probe.stateRoot, "trust-pgid");
        if (fs.existsSync(trustGroupPath)) {
          const trustGroup = Number.parseInt(fs.readFileSync(trustGroupPath, "utf8"), 10);
          try { process.kill(-trustGroup, "SIGKILL"); } catch {}
        }
        if (retained) await disposeRetainedGroupMember(retained);
        if (child?.exitCode === null && child?.signalCode === null) {
          try { process.kill(-child.pid, "SIGKILL"); } catch {}
        }
        fs.rmSync(probe.root, { recursive: true, force: true });
      }
    });
  }
});

test("bounded command supervisor waits for retained zombie absence on timeout", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "osrs-adapter-supervisor-timeout."));
  let retained;
  try {
    const groupPath = path.join(root, "group.pid");
    const childScript = path.join(root, "blocked-child.zsh");
    fs.writeFileSync(childScript, [
      "#!/bin/zsh -f",
      `/usr/bin/printf '%s\\n' \"$$\" > ${JSON.stringify(groupPath)}`,
      "setopt TRAPS_ASYNC",
      "trap 'exit 0' TERM",
      `while [[ ! -e ${JSON.stringify(path.join(root, "retained-member-ready"))} ]]; do /bin/sleep 0.02; done`,
      "while true; do /bin/sleep 60; done",
      ""
    ].join("\n"), { mode: 0o700 });
    fs.chmodSync(childScript, 0o700);
    const supervisor = path.resolve(workerRoot, "../scripts/run-bounded-command.pl");
    const child = spawn(supervisor, ["1", childScript], {
      stdio: ["ignore", "pipe", "pipe"]
    });
    const observed = observeChild(child);
    await waitForPath(groupPath, 10_000);
    retained = startRetainedGroupMember(root, groupPath, root);
    await waitForPath(retained.readyPath, 10_000);
    await delay(6_250);
    assertRetainedGroupMember(retained, groupPath);
    assert.equal(child.exitCode, null, "timeout returned while retained zombie kept the group live");
    assert.equal(child.signalCode, null, "timeout supervisor was signaled while the group remained live");
    await releaseRetainedGroupMember(retained);
    const result = await observed.result;
    assert.equal(result.status, 124, result.stderr || result.stdout);
    const childProcessGroup = Number.parseInt(fs.readFileSync(groupPath, "utf8"), 10);
    assert.throws(() => process.kill(-childProcessGroup, 0), { code: "ESRCH" });
  } finally {
    killProcessGroupFromFile(path.join(root, "group.pid"));
    if (retained) await disposeRetainedGroupMember(retained);
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("bounded command supervisor waits for retained zombie before ordinary status", async (context) => {
  for (const expectedStatus of [0, 37]) {
    await context.test(`exit ${expectedStatus}`, async () => {
      const root = fs.mkdtempSync(path.join(os.tmpdir(), "osrs-adapter-supervisor-status."));
      let retained;
      try {
        const groupPath = path.join(root, "group.pid");
        const childScript = path.join(root, "ordinary-child.zsh");
        fs.writeFileSync(childScript, [
          "#!/bin/zsh -f",
          `/usr/bin/printf '%s\\n' \"$$\" > ${JSON.stringify(groupPath)}`,
          `while [[ ! -e ${JSON.stringify(path.join(root, "retained-member-ready"))} ]]; do /bin/sleep 0.02; done`,
          `exit ${expectedStatus}`,
          ""
        ].join("\n"), { mode: 0o700 });
        fs.chmodSync(childScript, 0o700);
        const supervisor = path.resolve(workerRoot, "../scripts/run-bounded-command.pl");
        const child = spawn(supervisor, ["30", childScript], {
          stdio: ["ignore", "pipe", "pipe"]
        });
        const observed = observeChild(child);
        await waitForPath(groupPath, 10_000);
        retained = startRetainedGroupMember(root, groupPath, root);
        await waitForPath(retained.readyPath, 10_000);
        await delay(5_750);
        assertRetainedGroupMember(retained, groupPath);
        assert.equal(child.exitCode, null, "ordinary status returned before group absence");
        assert.equal(child.signalCode, null, "ordinary supervisor was signaled before group absence");
        await releaseRetainedGroupMember(retained);
        const result = await observed.result;
        assert.equal(result.status, expectedStatus, result.stderr || result.stdout);
        const childProcessGroup = Number.parseInt(fs.readFileSync(groupPath, "utf8"), 10);
        assert.throws(() => process.kill(-childProcessGroup, 0), { code: "ESRCH" });
      } finally {
        killProcessGroupFromFile(path.join(root, "group.pid"));
        if (retained) await disposeRetainedGroupMember(retained);
        fs.rmSync(root, { recursive: true, force: true });
      }
    });
  }
});

test("build and install scripts keep trusted inputs and one transactional bundle", () => {
  const scriptsRoot = path.resolve(workerRoot, "../scripts");
  const build = fs.readFileSync(path.join(scriptsRoot, "build-apps.sh"), "utf8");
  const install = fs.readFileSync(path.join(scriptsRoot, "install-local.sh"), "utf8");
  const transaction = fs.readFileSync(path.join(scriptsRoot, "install-transaction.swift"), "utf8");
  const verifyBuild = fs.readFileSync(path.join(scriptsRoot, "verify-build-closure.mjs"), "utf8");
  const verifyInstalled = fs.readFileSync(path.join(scriptsRoot, "verify-installed-bundle.mjs"), "utf8");

  assert.match(build, /TRUSTED_SOURCE_ROOT_MISMATCH/);
  assert.match(build, /TRUSTED_SOURCE_COMMIT_MISMATCH/);
  assert.match(build, /SOURCE_NOT_CLEAN/);
  assert.doesNotMatch(build, /OSRS_ADAPTER_SIGNING_POLICY|OSRS_ADAPTER_NODE_ARCHIVE/);
  assert.doesNotMatch(build, /\/opt\/homebrew\/bin\/(?:node|npm)/);
  assert.match(build, /node-v26\.4\.0-darwin-arm64/);
  assert.match(build, /npm_version="11\.17\.0"/);
  assert.match(build, /tool_npm_cli=.*npm-cli\.js/);
  assert.match(build, /--cache "\$temporary\/npm-cache"/);
  assert.doesNotMatch(build, /\.npm\/_cacache/);
  assert.match(build, /swift_tool="\/Applications\/Xcode\.app\/Contents\/Developer\/Toolchains\/XcodeDefault\.xctoolchain\/usr\/bin\/swift"/);
  assert.match(build, /\/usr\/bin\/env -i HOME=.*PATH=/);
  assert.doesNotMatch(build, /== v26\.\*/);
  assert.match(build, /Contents\/MacOS\/osrs-explorerctl/);
  assert.match(build, /node_entitlements="\$root\/Resources\/NodeRuntime\.entitlements"/);
  assert.match(build, /signing_arguments\+=\(--generate-entitlement-der --entitlements "\$node_entitlements"\)/);
  assert.doesNotMatch(build, /allow-unsigned-executable-memory/);
  assert.match(install, /TRUSTED_SOURCE_ROOT_MISMATCH/);
  assert.match(install, /SIGNING_POLICY_PATH_MISMATCH/);
  assert.match(
    install,
    /fixed_signing_policy="\$HOME\/Library\/Application Support\/OSRS Explorer Adapter\/signing-policy\.json"/
  );
  assert.doesNotMatch(install, /config\/release-signing-policy\.json/);
  assert.doesNotMatch(install, /\/opt\/homebrew\/bin\/node/);
  assert.match(install, /node_archive_sha256="bef4c7e75087c029835f519a7ba640eba52fa617fadb3a9049828ff3b45b57dd"/);
  assert.match(install, /node_binary_sha256="d23e520f5bcd497bdd0c6a6242356a4fd255abaceba7c3549727caacb936ddae"/);
  assert.match(install, /\/usr\/bin\/env -i HOME=.*PATH=/);
  assert.doesNotMatch(install, /== v26\.\*/);
  assert.match(install, /install-transaction\.swift/);
  assert.doesNotMatch(install, /stable_cli|atomic-replace\.swift/);
  assert.match(transaction, /LOCK_EX \| LOCK_NB/);
  assert.match(transaction, /INSTALL_POST_VERIFY_FAILED/);
  assert.match(transaction, /INSTALL_ROLLBACK_FAILED/);
  assert.match(transaction, /process\.executableURL = node/);
  assert.doesNotMatch(transaction, /\/usr\/bin\/env/);
  assert.match(verifyBuild, /sourceRootArgument, sourceCommit, signingPolicyArgument/);
  assert.match(verifyInstalled, /sourceRootArgument, sourceCommit, signingPolicyArgument/);
  assert.match(verifyBuild, /LIVE_LIBVIPS_VERSION_MISMATCH/);
  assert.match(verifyInstalled, /INSTALLED_LIVE_LIBVIPS_VERSION_MISMATCH/);
  for (const source of [
    fs.readFileSync(path.join(scriptsRoot, "write-build-closure.mjs"), "utf8"),
    verifyBuild,
    verifyInstalled
  ]) {
    assert.doesNotMatch(source, /extract-certificates/);
    assert.match(source, /designated-requirement-leaf-sha1/);
    assert.match(source, /SIGNING_CERTIFICATE_REQUIREMENT_MISMATCH/);
    assert.match(source, /combinedProcessOutput/);
    assert.match(source, /readEffectiveEntitlements/);
  }
});

function runProductionRollbackProbe(scenario) {
  const probe = prepareProductionRollbackProbe(scenario);
  const result = spawnSync(probe.script, probe.args, {
    env: probe.env,
    encoding: "utf8"
  });
  return { ...probe, result };
}

function prepareProductionRollbackProbe(scenario) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "osrs-adapter-production-rollback."));
  const stateRoot = path.join(root, "state");
  const home = path.join(root, "home");
  const temporary = path.join(root, "tmp");
  fs.mkdirSync(stateRoot, { recursive: true, mode: 0o700 });
  fs.mkdirSync(home, { recursive: true, mode: 0o700 });
  fs.mkdirSync(temporary, { recursive: true, mode: 0o700 });
  const shim = path.join(root, "security-shim.zsh");
  fs.writeFileSync(shim, [
    "#!/bin/zsh -f",
    "set -u",
    'state="$OSRS_SIGNING_SHIM_STATE"',
    'scenario="$OSRS_SIGNING_SHIM_SCENARIO"',
    'command="$1"',
    "shift",
    '/usr/bin/printf \'%s %s\\n\' "$command" "$*" >> "$state/commands.log"',
    'case "$command" in',
    "  find-certificate)",
    '    [[ "$scenario" == "lookup-failure" ]] && exit 72',
    '    [[ -e "$state/certificate.pem" ]] && { /bin/cat "$state/certificate.pem"; exit 0; }',
    '    [[ "$scenario" == "empty-absence" ]] && exit 0',
    "    exit 44",
    "    ;;",
    "  import)",
    '    [[ " $* " == *" -t cert "* ]] && { /bin/cp "$1" "$state/certificate.pem"; exit 0; }',
    '    [[ " $* " == *" -t priv "* ]] && {',
    '      /usr/bin/touch "$state/private-key" "$state/identity"',
    '      [[ "$scenario" == "trust-failure-cleanup-nonzero" || "$scenario" == "block-during-trust" ]] && exit 0',
    "      exit 71",
    "    }",
    "    exit 64",
    "    ;;",
    "  add-trusted-cert)",
    '    [[ " $* " == *" -r trustRoot "* && " $* " == *" -p codeSign "* ]] || exit 64',
    '    /usr/bin/touch "$state/trust"',
    '    [[ "$scenario" == "block-during-trust" ]] && {',
    '      setopt TRAPS_ASYNC',
    "      trap 'exit 0' TERM",
    '      /usr/bin/printf \'%s\\n\' "$$" > "$state/trust-pgid"',
    '      while [[ ! -e "$state/retained-member-ready" ]]; do /bin/sleep 0.02; done',
    '      /usr/bin/touch "$state/trust-ready"',
    '      while true; do /bin/sleep 60; done',
    "    }",
    '    [[ "$scenario" == "trust-failure-cleanup-nonzero" ]] && exit 73',
    "    exit 0",
    "    ;;",
    "  delete-identity)",
    '    [[ -e "$state/trust-pgid" ]] && {',
    '      trust_pgid="$(/bin/cat "$state/trust-pgid")"',
    '      /bin/kill -0 -- "-$trust_pgid" 2>/dev/null && /usr/bin/touch "$state/rollback-raced"',
    "    }",
    '    [[ "$scenario" == "cleanup-failure" ]] && exit 72',
    '    /bin/rm -f "$state/certificate.pem" "$state/private-key" "$state/identity" "$state/trust"',
    '    [[ "$scenario" == "trust-failure-cleanup-nonzero" ]] && exit 72',
    "    exit 0",
    "    ;;",
    "  delete-certificate)",
    '    [[ "$scenario" == "cleanup-failure" ]] && exit 72',
    '    /bin/rm -f "$state/certificate.pem" "$state/trust"',
    "    exit 0",
    "    ;;",
    "  find-key)",
    '    [[ -e "$state/private-key" ]] && { print "SYNTHETIC_PRIVATE_KEY"; exit 0; }',
    '    print -u2 "security: SecItemCopyMatching: The specified item could not be found in the keychain."',
    "    exit 1",
    "    ;;",
    "  verify-cert)",
    '    [[ -e "$state/trust" ]] && exit 0',
    "    exit 1",
    "    ;;",
    "  *) exit 64 ;;",
    "esac",
    ""
  ].join("\n"), { mode: 0o700 });
  fs.chmodSync(shim, 0o700);

  return {
    root,
    stateRoot,
    home,
    script: path.resolve(workerRoot, "../scripts/create-local-signing-identity.sh"),
    args: ["--offline-security-shim", shim],
    env: {
      ...process.env,
      HOME: home,
      TMPDIR: temporary,
      OSRS_SIGNING_SHIM_STATE: stateRoot,
      OSRS_SIGNING_SHIM_SCENARIO: scenario
    }
  };
}

async function waitForPath(target, timeoutMilliseconds) {
  const deadline = Date.now() + timeoutMilliseconds;
  while (Date.now() < deadline) {
    if (fs.existsSync(target)) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`PATH_WAIT_TIMEOUT:${target}`);
}

function startRetainedGroupMember(root, groupPath, stateRoot) {
  const script = path.join(root, "retain-group-member.pl");
  const readyPath = path.join(stateRoot, "retained-member-ready");
  const releasePath = path.join(stateRoot, "retained-member-release");
  const memberPidPath = path.join(stateRoot, "retained-member-pid");
  fs.writeFileSync(script, [
    "#!/usr/bin/perl",
    "use strict;",
    "use warnings;",
    "use POSIX qw(setpgid);",
    "my ($group_path, $ready_path, $release_path, $member_pid_path) = @ARGV;",
    "my $group;",
    "for (1 .. 500) {",
    "    if (open my $fh, q{<}, $group_path) {",
    "        $group = <$fh>;",
    "        close $fh;",
    "        chomp $group if defined $group;",
    "        last if defined $group && $group =~ /^\\d+$/;",
    "    }",
    "    select undef, undef, undef, 0.02;",
    "}",
    "defined $group && $group =~ /^\\d+$/ or exit 64;",
    "pipe(my $reader, my $writer) or exit 125;",
    "my $member = fork();",
    "defined $member or exit 125;",
    "if ($member == 0) {",
    "    close $reader;",
    "    setpgid(0, $group) == 0 or exit 126;",
    "    print {$writer} qq{ready\\n};",
    "    close $writer;",
    "    $SIG{HUP} = q{IGNORE};",
    "    $SIG{INT} = q{IGNORE};",
    "    $SIG{TERM} = q{IGNORE};",
    "    while (1) { select undef, undef, undef, 60; }",
    "}",
    "close $writer;",
    "my $ack = <$reader>;",
    "close $reader;",
    "defined $ack && $ack eq qq{ready\\n} or exit 126;",
    "open my $pid_fh, q{>}, $member_pid_path or exit 125;",
    "print {$pid_fh} qq{$member\\n};",
    "close $pid_fh;",
    "open my $ready_fh, q{>}, $ready_path or exit 125;",
    "print {$ready_fh} qq{ready\\n};",
    "close $ready_fh;",
    "while (!-e $release_path) {",
    "    select undef, undef, undef, 0.02;",
    "}",
    "waitpid($member, 0) == $member or exit 125;",
    "exit 0;",
    ""
  ].join("\n"), { mode: 0o700 });
  fs.chmodSync(script, 0o700);
  const child = spawn("/usr/bin/perl", [
    script,
    groupPath,
    readyPath,
    releasePath,
    memberPidPath
  ], { stdio: ["ignore", "pipe", "pipe"] });
  return {
    child,
    observed: observeChild(child),
    readyPath,
    releasePath,
    memberPidPath
  };
}

async function releaseRetainedGroupMember(retained) {
  if (!fs.existsSync(retained.releasePath)) fs.writeFileSync(retained.releasePath, "release\n");
  const result = await Promise.race([
    retained.observed.result,
    delay(2_000).then(() => null)
  ]);
  assert.notEqual(result, null, "retained member was not already terminated when released");
  assert.equal(result.status, 0, result.stderr || result.stdout);
}

async function disposeRetainedGroupMember(retained) {
  if (retained.child.exitCode !== null) return;
  if (!fs.existsSync(retained.releasePath)) fs.writeFileSync(retained.releasePath, "release\n");
  const outcome = await Promise.race([
    retained.observed.result,
    delay(1_000).then(() => null)
  ]);
  if (outcome === null && retained.child.exitCode === null) {
    retained.child.kill("SIGKILL");
    await retained.observed.result;
  }
}

function removeRetainedGroupMarkers(retained) {
  for (const target of [
    retained.readyPath,
    retained.releasePath,
    retained.memberPidPath
  ]) fs.rmSync(target, { force: true });
}

function assertRetainedGroupMember(retained, groupPath) {
  const memberPid = Number.parseInt(fs.readFileSync(retained.memberPidPath, "utf8"), 10);
  assert.doesNotThrow(() => process.kill(memberPid, 0), "retained group member disappeared early");
  const group = Number.parseInt(fs.readFileSync(groupPath, "utf8"), 10);
  try {
    process.kill(-group, 0);
  } catch (error) {
    assert.notEqual(error.code, "ESRCH", "process group disappeared before retained member release");
  }
}

function observeChild(child) {
  let stdout = "";
  let stderr = "";
  child.stdout?.setEncoding("utf8");
  child.stderr?.setEncoding("utf8");
  child.stdout?.on("data", (chunk) => { stdout += chunk; });
  child.stderr?.on("data", (chunk) => { stderr += chunk; });
  const result = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code, signal) => resolve({ status: code, signal, stdout, stderr }));
  });
  return { result };
}

function spawnInOwnProcessGroup(executable, args, options) {
  return spawn("/usr/bin/perl", [
    "-MPOSIX",
    "-e",
    "POSIX::setpgid(0, 0) == 0 or exit 126; exec @ARGV or exit 127",
    executable,
    ...args
  ], options);
}

function killProcessGroupFromFile(groupPath) {
  if (!fs.existsSync(groupPath)) return;
  const group = Number.parseInt(fs.readFileSync(groupPath, "utf8"), 10);
  if (!Number.isInteger(group) || group <= 0) return;
  try { process.kill(-group, "SIGKILL"); } catch {}
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function codesignResult(stdout, stderr = "", status = 0) {
  return { status, signal: null, stdout, stderr };
}

function entitlementsPlist(entitlements) {
  const entries = Object.entries(entitlements).map(([key, value]) =>
    `\t<key>${key}</key>\n\t<${value ? "true" : "false"}/>`
  ).join("\n");
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<plist version="1.0">',
    "<dict>",
    entries,
    "</dict>",
    "</plist>",
    ""
  ].join("\n");
}

function entitlementsDER(entries) {
  const encodedEntries = entries.map(([name, value]) => derElement(
    0x30,
    Buffer.concat([
      derElement(0x0c, Buffer.from(name, "utf8")),
      derElement(0x01, Buffer.from([value ? 0xff : 0x00]))
    ])
  ));
  return derElement(
    0x70,
    Buffer.concat([
      derElement(0x02, Buffer.from([0x01])),
      derElement(0xb0, Buffer.concat(encodedEntries))
    ])
  );
}

function derElement(tag, content) {
  return Buffer.concat([Buffer.from([tag]), derLength(content.length), content]);
}

function derLength(length) {
  if (length < 0x80) return Buffer.from([length]);
  const bytes = [];
  for (let remaining = length; remaining > 0; remaining = Math.floor(remaining / 0x100)) {
    bytes.unshift(remaining % 0x100);
  }
  return Buffer.from([0x80 | bytes.length, ...bytes]);
}

function releaseManifest(trusted) {
  const requirement = (identifier) =>
    `identifier \"${identifier}\" and certificate leaf = H\"${trusted.certificateSHA1}\"`;
  const cli = {
    path: "Contents/MacOS/osrs-explorerctl",
    sha256: "cli-sha",
    signing_identifier: FIXED_CLI_IDENTIFIER,
    signing_certificate_sha256: trusted.certificateSHA256,
    signing_certificate_proof: "designated-requirement-leaf-sha1",
    designated_requirement: requirement(FIXED_CLI_IDENTIFIER),
    hardened_runtime: true,
    entitlements: {}
  };
  const signedNodeSHA256 = "C".repeat(64);
  const nodeIdentifier = `${FIXED_BUNDLE_IDENTIFIER}.nested.node`;
  const node = {
    path: NODE_RUNTIME_PATH,
    sha256: signedNodeSHA256,
    signing_identifier: nodeIdentifier,
    signing_certificate_sha256: trusted.certificateSHA256,
    signing_certificate_proof: "designated-requirement-leaf-sha1",
    designated_requirement: requirement(nodeIdentifier),
    hardened_runtime: true,
    entitlements: { ...NODE_RUNTIME_ENTITLEMENTS }
  };
  return {
    schema_version: 5,
    source: {
      root: trusted.sourceRoot,
      git_head: trusted.sourceCommit,
      git_status_sha256: sha256(Buffer.alloc(0))
    },
    signing_policy: {
      path: trusted.signingPolicyPath,
      identity: FIXED_SIGNING_IDENTITY,
      certificate_sha256: trusted.certificateSHA256,
      certificate_sha1: trusted.certificateSHA1
    },
    adapter_bundle: {
      bundle_identifier: FIXED_BUNDLE_IDENTIFIER,
      source_commit: trusted.sourceCommit,
      signing_certificate_sha256: trusted.certificateSHA256,
      signing_certificate_proof: "designated-requirement-leaf-sha1",
      designated_requirement: requirement(FIXED_BUNDLE_IDENTIFIER),
      hardened_runtime: true,
      entitlements: {}
    },
    mach_o: [cli, node],
    control_utility: { ...cli },
    toolchains: {
      xcode: { ...PINNED_RELEASE_TOOLCHAIN.xcode },
      swift: { ...PINNED_RELEASE_TOOLCHAIN.swift },
      swiftc: { ...PINNED_RELEASE_TOOLCHAIN.swiftc },
      node: { ...PINNED_RELEASE_TOOLCHAIN.node },
      npm: { ...PINNED_RELEASE_TOOLCHAIN.npm }
    },
    node_runtime: {
      path: NODE_RUNTIME_PATH,
      version: PINNED_RELEASE_TOOLCHAIN.node.version,
      sha256: signedNodeSHA256,
      source_binary_sha256: PINNED_RELEASE_TOOLCHAIN.node.sha256,
      source_archive_sha256: PINNED_RELEASE_TOOLCHAIN.node.source_archive_sha256
    },
    worker_dependencies: {
      sharp: { version: PINNED_RELEASE_TOOLCHAIN.sharp.version },
      libvips: {
        package_name: PINNED_RELEASE_TOOLCHAIN.libvips.package_name,
        version: PINNED_RELEASE_TOOLCHAIN.libvips.package_version,
        runtime_version: PINNED_RELEASE_TOOLCHAIN.libvips.runtime_version
      }
    }
  };
}

function command(executable, commandArguments, environment) {
  const result = spawnSync(executable, commandArguments, {
    env: environment,
    encoding: "utf8"
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return result.stdout.trim();
}
