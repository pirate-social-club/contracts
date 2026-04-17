#!/usr/bin/env bun

import fs from "node:fs";
import path from "node:path";

import { computeAddress } from "ethers";
import { URDecoder } from "@ngraveio/bc-ur";
import { CryptoAccount } from "@keystonehq/bc-ur-registry/dist/CryptoAccount";
import { CryptoHDKey } from "@keystonehq/bc-ur-registry/dist/CryptoHDKey";

function usage() {
  console.error(`Usage:
  pair-keystone-account.mjs --alias <name> [options]

Imports a Keystone account export QR payload once and stores the account
metadata locally so later commands can use --account <alias> instead of raw
XFP/path flags.

Required:
  --alias <name>              Local account alias to save, e.g. keystone-prod

Input:
  --ur-file <file>            Text file containing UR fragments, one per line
                              If omitted, UR fragments are read from stdin

Output:
  --outdir <dir>              Account store directory
                              Default: story/delivery/accounts

Other:
  -h, --help                  Show help
`);
  process.exit(1);
}

function fail(message, code = 1) {
  console.error(message);
  process.exit(code);
}

function parseArgs(argv) {
  const args = {
    alias: "",
    urFile: "",
    outdir: "",
  };

  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case "--alias":
        args.alias = argv[++i] ?? "";
        break;
      case "--ur-file":
        args.urFile = argv[++i] ?? "";
        break;
      case "--outdir":
        args.outdir = argv[++i] ?? "";
        break;
      case "-h":
      case "--help":
        usage();
        break;
      default:
        fail(`unknown argument: ${arg}`);
    }
  }

  if (!args.alias) fail("--alias is required");
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(args.alias)) {
    fail("--alias must use only letters, digits, dot, dash, or underscore");
  }
  return args;
}

function readUrLines(filePath) {
  const raw = filePath
    ? fs.readFileSync(filePath, "utf8")
    : fs.readFileSync(0, "utf8");

  const lines = raw
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);

  if (lines.length === 0) {
    fail(filePath ? `no UR fragments found in ${filePath}` : "no UR fragments found on stdin");
  }

  return lines;
}

function decodeRegistryItem(parts) {
  const decoder = new URDecoder();

  for (const part of parts) {
    decoder.receivePart(part);
    if (decoder.isSuccess()) break;
  }

  if (!decoder.isComplete()) {
    fail(`pairing UR incomplete: received ${parts.length} fragment(s), decoder still needs more`);
  }
  if (!decoder.isSuccess()) {
    fail(`pairing UR decode failed: ${decoder.resultError() ?? "unknown error"}`);
  }

  const ur = decoder.resultUR();
  switch (ur.type) {
    case "crypto-account":
      return CryptoAccount.fromCBOR(ur.cbor);
    case "crypto-hdkey":
      return CryptoHDKey.fromCBOR(ur.cbor);
    default:
      fail(`unsupported pairing UR type: ur:${ur.type}`);
  }
}

function keypathToString(keypath) {
  if (!keypath) return null;
  const pathString = keypath.getPath?.() ?? null;
  return pathString ? `m/${pathString}` : null;
}

function sourceFingerprintHex(keypath) {
  const fp = keypath?.getSourceFingerprint?.();
  return fp ? Buffer.from(fp).toString("hex").toUpperCase() : null;
}

function describeHdKey(hdKey, masterFingerprintHex = null) {
  const key = hdKey.getKey?.();
  if (!key) {
    fail("Keystone account export has no public key material");
  }

  const address = computeAddress(`0x${Buffer.from(key).toString("hex")}`);
  const origin = hdKey.getOrigin?.();
  const children = hdKey.getChildren?.();

  const originPath = keypathToString(origin);
  const childPath = children?.getPath?.() ?? null;
  const derivationPath = [originPath, childPath].filter(Boolean).join("/");

  const xfp =
    sourceFingerprintHex(origin) ||
    masterFingerprintHex ||
    (hdKey.getParentFingerprint?.()
      ? Buffer.from(hdKey.getParentFingerprint()).toString("hex").toUpperCase()
      : null);

  return {
    address,
    xfp,
    derivationPath: derivationPath || null,
    publicKey: `0x${Buffer.from(key).toString("hex")}`,
    bip32Key: hdKey.getBip32Key?.() ?? null,
    name: hdKey.getName?.() ?? null,
    note: hdKey.getNote?.() ?? null,
  };
}

function extractAccountInfo(item) {
  if (item instanceof CryptoHDKey) {
    return describeHdKey(item, null);
  }

  if (item instanceof CryptoAccount) {
    const masterFingerprintHex = Buffer.from(item.getMasterFingerprint()).toString("hex").toUpperCase();
    const outputs = item.getOutputDescriptors?.() ?? [];
    for (const output of outputs) {
      const hdKey = output.getHDKey?.();
      if (!hdKey) continue;
      const info = describeHdKey(hdKey, masterFingerprintHex);
      return {
        ...info,
        outputDescriptor: output.toString?.() ?? null,
      };
    }
    fail("crypto-account export did not contain an HD key output descriptor");
  }

  fail(`unsupported Keystone account export type: ${item?.getRegistryType?.()?.getType?.() ?? typeof item}`);
}

function main() {
  const args = parseArgs(process.argv);
  const parts = readUrLines(args.urFile ? path.resolve(args.urFile) : "");
  const item = decodeRegistryItem(parts);
  const accountInfo = extractAccountInfo(item);

  if (!accountInfo.xfp) {
    fail("could not extract source fingerprint from Keystone export");
  }
  if (!accountInfo.derivationPath) {
    fail("could not extract derivation path from Keystone export");
  }

  const outdir = path.resolve(
    args.outdir || path.join(path.dirname(new URL(import.meta.url).pathname), "..", "accounts"),
  );
  fs.mkdirSync(outdir, { recursive: true });

  const outFile = path.join(outdir, `${args.alias}.json`);
  const payload = {
    alias: args.alias,
    source: "keystone",
    address: accountInfo.address,
    xfp: accountInfo.xfp,
    derivationPath: accountInfo.derivationPath,
    publicKey: accountInfo.publicKey,
    bip32Key: accountInfo.bip32Key,
    outputDescriptor: accountInfo.outputDescriptor ?? null,
    importedAt: new Date().toISOString(),
  };

  fs.writeFileSync(outFile, JSON.stringify(payload, null, 2) + "\n");

  console.error(`ok  wrote ${outFile}`);
  console.error(`  address: ${payload.address}`);
  console.error(`  xfp:     ${payload.xfp}`);
  console.error(`  path:    ${payload.derivationPath}`);
}

main();
