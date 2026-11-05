// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Node resolution fallback for Storybook's own process, preloaded with
// `--import`. This module's packages and the consumer's sit in separate
// stores: a framework's peer (react, lit, astro) isn't in this module's
// store, and a consumer's file importing `storybook/test` finds nothing in
// the consumer's. When a bare specifier doesn't resolve from its importer,
// it's resolved again as if imported from each directory in
// TBHB_FALLBACK_PARENTS (JSON, file URLs), the consumer's project first.
//
// The fallback is registered twice: in this thread, for `require`, and as
// an asynchronous loader hook (resolve_loader.mjs), for `import`. Once any
// asynchronous loader is registered, as this file registers its own, `import`
// resolves off this thread, through those hooks only.

import { createRequire, register, registerHooks } from "node:module";
import { pathToFileURL } from "node:url";

const parents = JSON.parse(process.env.TBHB_FALLBACK_PARENTS ?? "[]");

// A package name, not a path, URL or builtin.
function isBare(specifier) {
  return !/^(\.|\/|[a-zA-Z]:|[a-z][a-z0-9+.-]*:|#)/.test(specifier);
}

registerHooks({
  resolve(specifier, context, nextResolve) {
    try {
      return nextResolve(specifier, context);
    } catch (error) {
      if (!isBare(specifier) || error?.code !== "MODULE_NOT_FOUND") {
        throw error;
      }
      // Another parentURL doesn't move where a `require` looks, so it
      // resolves through a require made for each parent instead.
      for (const parentURL of parents) {
        try {
          return {
            url: pathToFileURL(createRequire(parentURL).resolve(specifier))
              .href,
            shortCircuit: true,
          };
        } catch {
          // Not there either; try the next.
        }
      }
      throw error;
    }
  },
});

register(new URL("./resolve_loader.mjs", import.meta.url), {
  data: { parents },
});
