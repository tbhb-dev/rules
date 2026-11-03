// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// A knip reporter that prints how many project files knip analysed, for
// knip_test's output guard. launch.mjs runs it beside the default reporter.

export default function report({ counters }) {
  console.log(`knip: analysed ${counters.processed} project files`);
}
