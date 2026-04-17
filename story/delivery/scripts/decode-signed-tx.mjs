#!/usr/bin/env bun

import { Transaction } from "ethers";

function usage() {
  console.error("Usage: decode-signed-tx.mjs <signed_raw_tx_hex>");
  process.exit(1);
}

const input = process.argv[2]?.trim();
if (!input) usage();

try {
  const tx = Transaction.from(input);

  console.log(JSON.stringify({
    type: tx.type,
    chainId: tx.chainId == null ? null : tx.chainId.toString(),
    from: tx.from ? tx.from.toLowerCase() : null,
    nonce: tx.nonce,
    to: tx.to ? tx.to.toLowerCase() : null,
    data: typeof tx.data === "string" ? tx.data.toLowerCase() : "0x",
  }));
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  console.error(message);
  process.exit(1);
}
