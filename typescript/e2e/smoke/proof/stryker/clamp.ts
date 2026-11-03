// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

export function clamp(n: number, max: number): number {
  return n > max ? max : n;
}
