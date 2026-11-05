// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// The fallback of resolve_hooks.mjs as an asynchronous loader hook, which
// resolve_hooks.mjs registers with module.register. Once any loader is
// registered that way (Storybook registers its TypeScript loader), Node
// resolves `import` off the main thread, through the registered hooks only,
// where a hook from module.registerHooks doesn't run.

let parents = [];

export function initialize(data) {
  parents = data.parents;
}

const NOT_FOUND = new Set(["ERR_MODULE_NOT_FOUND", "MODULE_NOT_FOUND"]);

// A package name, not a path, URL or builtin.
function isBare(specifier) {
  return !/^(\.|\/|[a-zA-Z]:|[a-z][a-z0-9+.-]*:|#)/.test(specifier);
}

export async function resolve(specifier, context, nextResolve) {
  try {
    return await nextResolve(specifier, context);
  } catch (error) {
    if (!isBare(specifier) || !NOT_FOUND.has(error?.code)) {
      throw error;
    }
    for (const parentURL of parents) {
      try {
        return await nextResolve(specifier, { ...context, parentURL });
      } catch {
        // Not there either; try the next.
      }
    }
    throw error;
  }
}
