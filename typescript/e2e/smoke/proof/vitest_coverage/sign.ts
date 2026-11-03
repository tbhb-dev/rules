// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

export function sign(n: number): string {
  if (n < 0) {
    return "negative";
  }
  return "non-negative";
}
