// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import { a } from "./a.ts";

export const b = (): number => (a.length > 0 ? 1 : 0);
