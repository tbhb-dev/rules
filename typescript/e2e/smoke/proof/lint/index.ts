// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Planted: Biome's noDoubleEquals rule rejects loose equality.
export function planted(a: unknown, b: unknown): boolean {
  return a == b;
}
