// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Planted: a and b import each other.
import { b } from "./b.ts";

export const a = (): number => b() + 1;
