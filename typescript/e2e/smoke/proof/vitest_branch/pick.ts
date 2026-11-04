// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Every line and statement runs when pick(true) does; the false branch of
// the ternary is the only gap.
export function pick(flag: boolean): string {
  return flag ? "yes" : "no";
}
