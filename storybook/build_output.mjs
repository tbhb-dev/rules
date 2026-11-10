// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join, relative, sep } from "node:path";

// The framework needs absolute ids for its build-time SSR. Only the client
// marker and emitted HTML change; development and Vitest keep their ids.
export function astroBuild(root) {
  let outDir;
  return {
    name: "tbhb-storybook-astro-build",
    apply: "build",
    enforce: "post",
    configResolved(config) {
      outDir = config.build.outDir;
    },
    transform(code, id) {
      if (!id.endsWith(".astro")) {
        return null;
      }
      const marker = "__astro_component.moduleId = ";
      return {
        code: code.replace(
          `${marker}${JSON.stringify(id)};`,
          `${marker}${JSON.stringify(`./${relative(root, id).split(sep).join("/")}`)};`,
        ),
        map: null,
      };
    },
    transformIndexHtml: {
      order: "post",
      handler: (html) =>
        html.replace(/window\.FRAMEWORK_OPTIONS = (\{[^\n]*\});/, (_, json) => {
          const options = JSON.parse(json);
          // Used by the Node preset to locate Astro and its config, never by
          // the browser renderer. Keep all the consumer's other options.
          delete options.resolveFrom;
          return `window.FRAMEWORK_OPTIONS = ${JSON.stringify(options)};`;
        }),
    },
    closeBundle() {
      // The framework's prerender uses a Vite server, which enables Astro's
      // source annotations even in production. Keep their paths portable too.
      const path = join(outDir, "astro-prerendered-stories.json");
      if (existsSync(path)) {
        const stories = JSON.parse(readFileSync(path));
        for (const id of Object.keys(stories)) {
          // No real Windows Astro annotation has been observed. Accept either
          // separator after the root rather than assuming the host's separator.
          for (const separator of ["/", "\\"]) {
            stories[id] = stories[id].replaceAll(
              `data-astro-source-file="${root}${separator}`,
              'data-astro-source-file="/',
            );
          }
        }
        writeFileSync(path, JSON.stringify(stories));
      }
    },
  };
}
