#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

import { readOSRSReadiness } from "../src/perception.mjs";

const input = process.argv[2];
if (!input) {
  process.stderr.write("usage: osrs-readiness.mjs <host-produced-png>\n");
  process.exitCode = 64;
} else {
  const resolved = path.resolve(input);
  if (!fs.statSync(resolved).isFile()) {
    throw new Error("READINESS_CAPTURE_NOT_FILE");
  }
  const result = await readOSRSReadiness(resolved);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  if (result.status === "PRECISELY_BLOCKED") process.exitCode = 2;
}
