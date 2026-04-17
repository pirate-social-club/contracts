#!/usr/bin/env bun

import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";

import QRCode from "qrcode";
import { DataType, EthSignRequest } from "@keystonehq/bc-ur-registry-eth";

function usage() {
  console.error(`Usage:
  render-step-keystone-ur.mjs --step <step.json> (--xfp <8-hex> | --account <alias>) [options]

Generates an animated Keystone-compatible BC-UR eth-sign-request bundle from a
deploy.sh MODE=unsigned step JSON. The output is an HTML player plus one QR SVG
per UR fragment.

Required:
  --step <file>             Step JSON produced by deploy.sh MODE=unsigned
  --xfp <8-hex>             Source/master fingerprint for the signing account
  --account <alias>         Load account metadata from accounts/<alias>.json

Options:
  --path <hd-path>          Derivation path (default: m/44'/60'/0'/0/0)
  --origin <label>          Origin string shown on device (default: Pirate Story Delivery)
  --outdir <dir>            Output directory
  --fragment-len <n>        Max UR fragment length (default: 220)
  --frame-ms <n>            HTML playback interval in ms (default: 250)
  --width <px>              QR image width in px (default: 520)
  -h, --help                Show help
`);
  process.exit(1);
}

function fail(message, code = 1) {
  console.error(message);
  process.exit(code);
}

function parseArgs(argv) {
  const args = {
    step: "",
    xfp: "",
    account: "",
    hdPath: "m/44'/60'/0'/0/0",
    origin: "Pirate Story Delivery",
    outdir: "",
    fragmentLen: 220,
    frameMs: 250,
    width: 520,
  };

  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case "--step":
        args.step = argv[++i] ?? "";
        break;
      case "--xfp":
        args.xfp = argv[++i] ?? "";
        break;
      case "--account":
        args.account = argv[++i] ?? "";
        break;
      case "--path":
        args.hdPath = argv[++i] ?? "";
        break;
      case "--origin":
        args.origin = argv[++i] ?? "";
        break;
      case "--outdir":
        args.outdir = argv[++i] ?? "";
        break;
      case "--fragment-len":
        args.fragmentLen = Number(argv[++i] ?? "");
        break;
      case "--frame-ms":
        args.frameMs = Number(argv[++i] ?? "");
        break;
      case "--width":
        args.width = Number(argv[++i] ?? "");
        break;
      case "-h":
      case "--help":
        usage();
        break;
      default:
        fail(`unknown argument: ${arg}`);
    }
  }

  if (!args.step) fail("--step is required");
  if (!args.xfp && !args.account) fail("either --xfp or --account is required");
  if (args.xfp && args.account) fail("use either --xfp or --account, not both");
  if (args.xfp && !/^[0-9a-fA-F]{8}$/.test(args.xfp)) {
    fail("--xfp must be exactly 8 hex chars, e.g. F23F9FD2");
  }
  if (!Number.isFinite(args.fragmentLen) || args.fragmentLen < 20) {
    fail("--fragment-len must be a number >= 20");
  }
  if (!Number.isFinite(args.frameMs) || args.frameMs < 50) {
    fail("--frame-ms must be a number >= 50");
  }
  if (!Number.isFinite(args.width) || args.width < 128) {
    fail("--width must be a number >= 128");
  }

  return args;
}

function resolveAccount(args) {
  if (!args.account) {
    return {
      xfp: args.xfp.toUpperCase(),
      hdPath: args.hdPath,
      accountAlias: null,
      address: null,
    };
  }

  const accountFile = path.resolve(
    path.join(path.dirname(new URL(import.meta.url).pathname), "..", "accounts", `${args.account}.json`),
  );
  if (!fs.existsSync(accountFile)) {
    fail(`account file not found: ${accountFile}`);
  }

  const account = JSON.parse(fs.readFileSync(accountFile, "utf8"));
  if (!account.xfp || !/^[0-9a-fA-F]{8}$/.test(account.xfp)) {
    fail(`account file has invalid xfp: ${accountFile}`);
  }
  if (!account.derivationPath) {
    fail(`account file has no derivationPath: ${accountFile}`);
  }

  return {
    xfp: String(account.xfp).toUpperCase(),
    hdPath: String(account.derivationPath),
    accountAlias: args.account,
    address: account.address ? String(account.address) : null,
  };
}

function loadStep(stepFile) {
  if (!fs.existsSync(stepFile)) {
    fail(`step file not found: ${stepFile}`);
  }

  const raw = fs.readFileSync(stepFile, "utf8");
  const step = JSON.parse(raw);

  if (!step.unsignedRawTx || typeof step.unsignedRawTx !== "string") {
    fail(`step JSON has no unsignedRawTx: ${stepFile}`);
  }
  if (!step.from || typeof step.from !== "string") {
    fail(`step JSON has no from address: ${stepFile}`);
  }
  if (step.chainId == null) {
    fail(`step JSON has no chainId: ${stepFile}`);
  }

  return step;
}

function detectDataType(step) {
  if (step.feeModel === "legacy") {
    return DataType.transaction;
  }
  return DataType.typedTransaction;
}

function defaultOutdir(stepFile) {
  const base = path.basename(stepFile, ".json");
  return path.join(path.dirname(stepFile), "..", "keystone", base);
}

function esc(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

async function main() {
  const args = parseArgs(process.argv);
  const account = resolveAccount(args);
  const stepFile = path.resolve(args.step);
  const step = loadStep(stepFile);

  if (account.address && String(account.address).toLowerCase() !== String(step.from).toLowerCase()) {
    fail(`account ${args.account} address ${account.address} does not match step.from ${step.from}`);
  }

  const outdir = path.resolve(args.outdir || defaultOutdir(stepFile));
  fs.mkdirSync(outdir, { recursive: true });

  const requestId = randomUUID();
  const signData = Buffer.from(step.unsignedRawTx.replace(/^0x/, ""), "hex");
  const signRequest = EthSignRequest.constructETHRequest(
    signData,
    detectDataType(step),
    account.hdPath,
    account.xfp,
    requestId,
    Number(step.chainId),
    step.from,
    args.origin,
  );

  const encoder = signRequest.toUREncoder(args.fragmentLen);
  const parts = encoder.encodeWhole();

  const manifest = {
    requestType: "eth-sign-request",
    requestId,
    stepFile,
    stepIndex: step.stepIndex ?? null,
    stepName: step.stepName ?? "",
    from: step.from,
    chainId: step.chainId,
    hdPath: account.hdPath,
    xfp: account.xfp,
    accountAlias: account.accountAlias,
    fragmentLen: args.fragmentLen,
    frameMs: args.frameMs,
    frameCount: parts.length,
    dataType: detectDataType(step) === DataType.transaction ? "transaction" : "typedTransaction",
    outputDir: outdir,
    partsFile: path.join(outdir, "parts.txt"),
    htmlFile: path.join(outdir, "index.html"),
  };

  fs.writeFileSync(
    path.join(outdir, "request.json"),
    JSON.stringify(manifest, null, 2) + "\n",
  );
  fs.writeFileSync(path.join(outdir, "parts.txt"), parts.join("\n") + "\n");

  for (let i = 0; i < parts.length; i += 1) {
    const frameName = `frame-${String(i + 1).padStart(4, "0")}.svg`;
    await QRCode.toFile(path.join(outdir, frameName), parts[i], {
      type: "svg",
      margin: 1,
      width: args.width,
      errorCorrectionLevel: "M",
    });
  }

  const frameFiles = parts.map((_, i) => `frame-${String(i + 1).padStart(4, "0")}.svg`);
  const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>Keystone Sign Request - ${esc(step.stepName ?? "step")}</title>
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <style>
    :root { color-scheme: dark; }
    body {
      margin: 0;
      font-family: ui-sans-serif, system-ui, sans-serif;
      background: #0a0a0a;
      color: #f6f6f6;
      display: grid;
      place-items: center;
      min-height: 100vh;
    }
    .wrap {
      width: min(92vw, 760px);
      display: grid;
      gap: 16px;
      justify-items: center;
      text-align: center;
    }
    img {
      width: min(82vw, ${args.width}px);
      height: auto;
      background: #fff;
      padding: 12px;
      border-radius: 16px;
    }
    .meta {
      font-size: 16px;
      line-height: 1.4;
      color: #d7d7d7;
    }
    .meta strong {
      color: #fff;
      font-weight: 600;
    }
    .row {
      display: flex;
      gap: 12px;
      flex-wrap: wrap;
      justify-content: center;
    }
    button {
      background: #1f1f1f;
      color: #fff;
      border: 1px solid #3b3b3b;
      border-radius: 999px;
      font-size: 16px;
      padding: 10px 16px;
      cursor: pointer;
    }
  </style>
</head>
<body>
  <div class="wrap">
    <img id="frame" src="${frameFiles[0]}" alt="Keystone QR frame" />
    <div class="meta">
      <div><strong>Step ${esc(step.stepIndex ?? "?")}:</strong> ${esc(step.stepName ?? "")}</div>
      <div><strong>From:</strong> ${esc(step.from)}</div>
      <div><strong>Path:</strong> ${esc(account.hdPath)} <strong>XFP:</strong> ${esc(account.xfp)}</div>
      <div><strong>Request ID:</strong> ${esc(requestId)}</div>
      <div><strong>Frame:</strong> <span id="counter">1 / ${frameFiles.length}</span></div>
    </div>
    <div class="row">
      <button id="toggle" type="button">Pause</button>
      <button id="prev" type="button">Prev</button>
      <button id="next" type="button">Next</button>
    </div>
  </div>
  <script>
    const frames = ${JSON.stringify(frameFiles)};
    const frameMs = ${JSON.stringify(args.frameMs)};
    const img = document.getElementById("frame");
    const counter = document.getElementById("counter");
    const toggle = document.getElementById("toggle");
    const prev = document.getElementById("prev");
    const next = document.getElementById("next");
    let index = 0;
    let timer = null;
    function render() {
      img.src = frames[index];
      counter.textContent = \`\${index + 1} / \${frames.length}\`;
    }
    function start() {
      if (timer) return;
      timer = setInterval(() => {
        index = (index + 1) % frames.length;
        render();
      }, frameMs);
      toggle.textContent = "Pause";
    }
    function stop() {
      if (!timer) return;
      clearInterval(timer);
      timer = null;
      toggle.textContent = "Play";
    }
    toggle.addEventListener("click", () => (timer ? stop() : start()));
    prev.addEventListener("click", () => {
      stop();
      index = (index - 1 + frames.length) % frames.length;
      render();
    });
    next.addEventListener("click", () => {
      stop();
      index = (index + 1) % frames.length;
      render();
    });
    render();
    start();
  </script>
</body>
</html>`;

  fs.writeFileSync(path.join(outdir, "index.html"), html);

  console.error(`ok  wrote Keystone UR bundle to ${outdir}`);
  console.error(`  step:        ${step.stepIndex ?? "?"} (${step.stepName ?? "unknown"})`);
  console.error(`  frames:      ${parts.length}`);
  console.error(`  requestId:   ${requestId}`);
  console.error(`  html player: ${path.join(outdir, "index.html")}`);
  console.error(`  parts file:  ${path.join(outdir, "parts.txt")}`);
}

main().catch((error) => {
  const message = error instanceof Error ? error.stack || error.message : String(error);
  fail(message);
});
