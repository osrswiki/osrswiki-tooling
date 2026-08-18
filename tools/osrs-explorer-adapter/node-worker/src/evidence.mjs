import fs from "node:fs";
import path from "node:path";

import { canonicalJson, sha256 } from "./protocol.mjs";

export function writeImmutableJson(root, relativePath, value) {
  const destination = path.join(root, relativePath);
  const directory = path.dirname(destination);
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const data = `${JSON.stringify(value, null, 2)}\n`;
  const temporary = path.join(directory, `.${path.basename(destination)}.tmp-${process.pid}-${Date.now()}`);
  const fd = fs.openSync(temporary, "wx", 0o600);
  try {
    fs.writeFileSync(fd, data);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(temporary, destination);
  fs.chmodSync(destination, 0o444);
  return { path: destination, sha256: sha256(data) };
}

export function writeImmutableBuffer(root, relativePath, data) {
  const destination = path.join(root, relativePath);
  const directory = path.dirname(destination);
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const temporary = path.join(directory, `.${path.basename(destination)}.tmp-${process.pid}-${Date.now()}`);
  const fd = fs.openSync(temporary, "wx", 0o600);
  try {
    fs.writeFileSync(fd, data);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  fs.renameSync(temporary, destination);
  fs.chmodSync(destination, 0o444);
  return { path: destination, sha256: sha256(data), bytes: data.length };
}

export function resultDigest(value) {
  return sha256(canonicalJson(value));
}
