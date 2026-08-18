#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const [rootArgument, destinationArgument] = process.argv.slice(2);
if (!rootArgument || !destinationArgument) {
  throw new Error("usage: write-worker-runtime-closure.mjs <worker-root> <destination>");
}

const root = fs.realpathSync(rootArgument);
const destination = path.resolve(destinationArgument);
const files = walk(root).map((file) => describe(file, root));
const manifest = {
  schema_version: 1,
  files,
  closure_sha256: sha256(Buffer.from(canonicalJSON(files), "utf8"))
};
writeAtomic(destination, `${JSON.stringify(manifest, null, 2)}\n`, 0o444);

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

function describe(file, base) {
  const metadata = fs.statSync(file);
  return {
    path: path.relative(base, file),
    sha256: sha256(fs.readFileSync(file)),
    size: metadata.size,
    mode: (metadata.mode & 0o777).toString(8).padStart(4, "0")
  };
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

function writeAtomic(destinationPath, contents, mode) {
  const temporary = `${destinationPath}.tmp-${process.pid}-${crypto.randomUUID()}`;
  fs.writeFileSync(temporary, contents, { mode: 0o600, flag: "wx" });
  fs.renameSync(temporary, destinationPath);
  fs.chmodSync(destinationPath, mode);
}
