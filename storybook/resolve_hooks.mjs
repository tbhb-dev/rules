// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Node resolution fallback for Storybook's own process, preloaded with
// `--import`. This module's packages and the consumer's sit in separate
// stores: a framework's peer (react, lit, astro) isn't in this module's
// store, and a consumer's file importing `storybook/test` finds nothing in
// the consumer's. When a bare specifier doesn't resolve from its importer,
// it's resolved again as if imported from each directory in
// TBHB_FALLBACK_PARENTS (JSON, file URLs), the consumer's project first.

import { registerHooks } from "node:module";

const parents = JSON.parse(process.env.TBHB_FALLBACK_PARENTS ?? "[]");
const NOT_FOUND = new Set(["ERR_MODULE_NOT_FOUND", "MODULE_NOT_FOUND"]);

// A package name, not a path, URL or builtin.
function isBare(specifier) {
  return !/^(\.|\/|[a-zA-Z]:|[a-z][a-z0-9+.-]*:|#)/.test(specifier);
}

registerHooks({
  resolve(specifier, context, nextResolve) {
    try {
      return nextResolve(specifier, context);
    } catch (error) {
      if (!isBare(specifier) || !NOT_FOUND.has(error?.code)) {
        throw error;
      }
      for (const parentURL of parents) {
        try {
          return nextResolve(specifier, { ...context, parentURL });
        } catch {
          // Not there either; try the next.
        }
      }
      throw error;
    }
  },
});
