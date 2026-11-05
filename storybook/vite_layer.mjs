// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// The Vite layer the generated Storybook config applies after the
// consumer's own viteFinal, in every mode.
//
// Resolution: this module's packages and the consumer's sit in separate
// stores, so a bare import that doesn't resolve from its importer is
// resolved again from each of `roots`, the consumer's project first. A
// framework's peer (react, lit, astro) then comes from the consumer, and a
// consumer's story importing `storybook/test` from this module.
//
// Dev under a base path (`base` set): Vite serves its own modules under the
// base, the browser opens the HMR socket through `clientPort`, the port the
// server is reached on, and the one module path Storybook's iframe writes
// as an absolute `/@id/` URL gets the base too.

import { existsSync } from "node:fs";
import { dirname, join } from "node:path";

// A package name, not a path, URL, virtual module or builtin.
function isBare(source) {
  return !/^(\.|\/|\0|[a-zA-Z]:|[a-z][a-z0-9+.-]*:|#)/.test(source);
}

function fallbackResolve(roots) {
  return {
    name: "tbhb-storybook-fallback-resolve",
    enforce: "pre",
    async resolveId(source, importer, options) {
      if (!isBare(source) || importer === undefined) {
        return null;
      }
      const opts = { ...options, skipSelf: true };
      const found = await this.resolve(source, importer, opts);
      if (found) {
        return found;
      }
      for (const root of roots) {
        const fallback = await this.resolve(
          source,
          join(root, "package.json"),
          opts,
        );
        if (fallback) {
          return fallback;
        }
      }
      return null;
    },
  };
}

// Storybook's iframe writes some of its scripts at root-relative URLs
// (`/@id/...`, `/vite-inject-mocker-entry.js`) that Vite's base doesn't
// reach; each gets the base, and the server in front strips it again.
function baseHtml(base) {
  const rooted = /\b(src|href)="\/(?!\/)/g;
  return {
    name: "tbhb-storybook-base-html",
    enforce: "post",
    transformIndexHtml: {
      order: "post",
      handler: (html) =>
        html.replace(rooted, (match, attr, offset) =>
          html.startsWith(base, offset + match.length - 1)
            ? match
            : `${attr}="${base}`,
        ),
    },
  };
}

// The package name of a bare specifier: `name` or `@scope/name`.
function packageName(specifier) {
  const parts = specifier.split("/");
  return specifier.startsWith("@") ? parts.slice(0, 2).join("/") : parts[0];
}

// Whether a package resolves the way Node finds one, from the nearest
// node_modules at or above `dir`.
function resolvesFrom(dir, name) {
  for (;;) {
    if (existsSync(join(dir, "node_modules", name, "package.json"))) {
      return true;
    }
    const parent = dirname(dir);
    if (parent === dir) {
      return false;
    }
    dir = parent;
  }
}

// In dev the project's root is the consumer's workspace, from which this
// module's packages don't resolve, so Vite can't pre-bundle them: they move
// from optimizeDeps.include to exclude and load as they are, through the
// fallback resolution.
function optimizeDeps(config, root) {
  const target = (id) => id.split(">").pop().trim();
  const include = config.optimizeDeps?.include ?? [];
  const missing = include.filter(
    (id) => !resolvesFrom(root, packageName(target(id))),
  );
  return {
    ...config.optimizeDeps,
    include: include.filter((id) => !missing.includes(id)),
    exclude: [...(config.optimizeDeps?.exclude ?? []), ...missing.map(target)],
  };
}

// Vite serves files only from the directories it allows; the packages
// behind both stores' links sit outside the project, in rules_js's stores.
export function fsAllow(config, [root, ...stores]) {
  // An explicit allow list replaces Vite's default, the project's root.
  const allow = config.server?.fs?.allow ?? [root];
  return {
    ...config.server,
    fs: { ...config.server?.fs, allow: [...allow, ...stores] },
  };
}

export function tbhbVite(config, { roots, stores, base, clientPort }) {
  const plugins = [fallbackResolve(roots), ...(config.plugins ?? [])];
  const server = fsAllow(config, [roots[0], ...stores]);
  if (!base) {
    return { ...config, server, plugins };
  }
  const hmr = typeof config.server?.hmr === "object" ? config.server.hmr : {};
  return {
    ...config,
    base,
    optimizeDeps: optimizeDeps(config, roots[0]),
    server: { ...server, hmr: { ...hmr, clientPort } },
    plugins: [...plugins, baseHtml(base)],
  };
}
