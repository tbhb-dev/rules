// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// The consumer's own Node toolchain must win: this module pins Node 24,
// while tbhb_rules registers none.
const ms = require("ms");
console.log("consumer node " + process.version + " ms=" + ms("2h"));
if (!process.version.startsWith("v24.")) {
  console.error("expected the consumer's Node 24, got " + process.version);
  process.exit(1);
}
