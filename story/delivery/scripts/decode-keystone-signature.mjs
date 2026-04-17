#!/usr/bin/env bun

import fs from "node:fs";
import path from "node:path";

import { Signature, Transaction } from "ethers";
import { URDecoder } from "@ngraveio/bc-ur";
import { ETHSignature } from "@keystonehq/bc-ur-registry-eth";

function usage() {
  console.error(`Usage:
  decode-keystone-signature.mjs --request <request.json> [options]

Decodes Keystone eth-signature UR fragments, verifies they match the original
request, reconstructs the signed raw transaction, and writes the hex to a file
that publish-signed.sh can broadcast.

Required:
  --request <file>             request.json produced by render-step-keystone-ur.mjs

Input options:
  --signature-ur-file <file>   Text file containing one UR fragment per line
                               If omitted, fragments are read from stdin

Output options:
  --out <file>                 Signed raw tx hex output file
                               Default: <request-dir>/signed.hex

Other:
  -h, --help                   Show help
`);
  process.exit(1);
}

function fail(message, code = 1) {
  console.error(message);
  process.exit(code);
}

function parseArgs(argv) {
  const args = {
    request: "",
    signatureUrFile: "",
    out: "",
  };

  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case "--request":
        args.request = argv[++i] ?? "";
        break;
      case "--signature-ur-file":
        args.signatureUrFile = argv[++i] ?? "";
        break;
      case "--out":
        args.out = argv[++i] ?? "";
        break;
      case "-h":
      case "--help":
        usage();
        break;
      default:
        fail(`unknown argument: ${arg}`);
    }
  }

  if (!args.request) fail("--request is required");
  return args;
}

function loadJson(filePath, label) {
  if (!fs.existsSync(filePath)) {
    fail(`${label} not found: ${filePath}`);
  }
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function normalizeAddress(address) {
  return String(address || "").trim().toLowerCase();
}

function normalizeUuidString(uuid) {
  return String(uuid || "").trim().toLowerCase().replaceAll("-", "");
}

function requestIdBufferToHex(buffer) {
  return Buffer.from(buffer).toString("hex").toLowerCase();
}

function parseSignatureBytes(signatureBuffer) {
  const bytes = Buffer.from(signatureBuffer);
  if (bytes.length !== 65) {
    fail(`expected 65-byte Ethereum signature from Keystone, got ${bytes.length} bytes`);
  }

  const r = `0x${bytes.subarray(0, 32).toString("hex")}`;
  const s = `0x${bytes.subarray(32, 64).toString("hex")}`;
  const rawV = bytes[64];
  const yParity = rawV >= 27 ? rawV - 27 : rawV;

  if (yParity !== 0 && yParity !== 1) {
    fail(`unsupported signature recovery byte: ${rawV}`);
  }

  return {
    r,
    s,
    yParity,
    rawV,
  };
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
    fail(filePath
      ? `no UR fragments found in ${filePath}`
      : "no UR fragments found on stdin");
  }

  return lines;
}

function decodeEthSignature(parts) {
  const decoder = new URDecoder();

  for (const part of parts) {
    decoder.receivePart(part);
    if (decoder.isSuccess()) break;
  }

  if (!decoder.isComplete()) {
    fail(`signature UR incomplete: received ${parts.length} fragment(s), decoder still needs more`);
  }
  if (!decoder.isSuccess()) {
    fail(`signature UR decode failed: ${decoder.resultError() ?? "unknown error"}`);
  }

  const ur = decoder.resultUR();
  if (ur.type !== "eth-signature") {
    fail(`expected ur:eth-signature, got ur:${ur.type}`);
  }

  return ETHSignature.fromCBOR(ur.cbor);
}

function main() {
  const args = parseArgs(process.argv);
  const requestFile = path.resolve(args.request);
  const request = loadJson(requestFile, "request file");
  const stepFile = request.stepFile ? path.resolve(request.stepFile) : "";

  if (!stepFile) {
    fail(`request file has no stepFile: ${requestFile}`);
  }

  const step = loadJson(stepFile, "step file");
  if (!step.unsignedRawTx || !step.from) {
    fail(`step file is missing unsignedRawTx or from: ${stepFile}`);
  }

  const signatureParts = readUrLines(args.signatureUrFile ? path.resolve(args.signatureUrFile) : "");
  const ethSignature = decodeEthSignature(signatureParts);

  const expectedRequestId = normalizeUuidString(request.requestId);
  const receivedRequestIdBuf = ethSignature.getRequestId();
  if (!receivedRequestIdBuf) {
    fail("Keystone signature does not include requestId");
  }

  const receivedRequestId = requestIdBufferToHex(receivedRequestIdBuf);
  if (expectedRequestId && receivedRequestId !== expectedRequestId) {
    fail(`requestId mismatch: signature has ${receivedRequestId}, request expects ${expectedRequestId}`);
  }

  const signatureFields = parseSignatureBytes(ethSignature.getSignature());

  const tx = Transaction.from(step.unsignedRawTx);
  tx.signature = Signature.from({
    r: signatureFields.r,
    s: signatureFields.s,
    yParity: signatureFields.yParity,
  });

  const signedRawTx = tx.serialized;
  const signedTx = Transaction.from(signedRawTx);

  const expectedFrom = normalizeAddress(step.from);
  const actualFrom = normalizeAddress(signedTx.from);
  if (!actualFrom) {
    fail("could not recover signer from reconstructed signed transaction");
  }
  if (actualFrom !== expectedFrom) {
    fail(`signer mismatch: signed tx recovers ${actualFrom}, step expects ${expectedFrom}`);
  }

  const outFile = path.resolve(
    args.out || path.join(path.dirname(requestFile), "signed.hex"),
  );
  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  fs.writeFileSync(outFile, `${signedRawTx}\n`);

  const metaFile = `${outFile}.json`;
  const meta = {
    requestFile,
    stepFile,
    requestId: request.requestId,
    receivedRequestId,
    from: actualFrom,
    nonce: signedTx.nonce,
    chainId: signedTx.chainId?.toString?.() ?? String(signedTx.chainId ?? ""),
    hash: signedTx.hash,
    signature: {
      r: signatureFields.r,
      s: signatureFields.s,
      rawV: signatureFields.rawV,
      yParity: signatureFields.yParity,
    },
  };
  fs.writeFileSync(metaFile, JSON.stringify(meta, null, 2) + "\n");

  console.error(`ok  wrote signed transaction to ${outFile}`);
  console.error(`  signer:    ${actualFrom}`);
  console.error(`  tx hash:   ${signedTx.hash}`);
  console.error(`  meta file: ${metaFile}`);
}

main();
