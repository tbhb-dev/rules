// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Planted: a floating promise, which only a type-aware rule can see.
async function work(): Promise<void> {}

export function planted(): void {
  work();
}
