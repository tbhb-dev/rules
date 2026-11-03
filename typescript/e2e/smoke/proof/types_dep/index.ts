// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import createDebug from "debug";

// Planted: humanize returns a string. Its type comes from @types/ms, a
// dependency of @types/debug; if @types/ms didn't resolve, humanize would
// be `any` under skipLibCheck and this would pass.
export const planted: number = createDebug.humanize(1000);
