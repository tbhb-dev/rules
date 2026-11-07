// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// The tool behind @tbhb_rules_tokens//:defs.bzl. It reads a DTCG 2025.10
// resolver document and the token files it names with Terrazzo's parser,
// pinned in this module, and runs one of three commands:
//
//   check <resolver> <options>      tokens_test: every file, every permutation
//   css <resolver> <out> <options>  tokens_css: one CSS file of custom properties
//   radix <outdir> <scale>...       radix_palettes: DTCG files from @radix-ui/colors
//
// <options> is one JSON object, which the rules write.
//
// Every problem is reported as `file: problem`, with the file relative to
// the directory the command runs in. Terrazzo itself reports a resolver's
// tokens against one document it merges in memory, whose line numbers match
// no file, so the checks that can name a file (types, aliases, cycles,
// missing tokens) run here first, over the files as written, and Terrazzo's
// own resolution runs last as a backstop.

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import * as radixColors from "@radix-ui/colors";
import {
  build,
  defineConfig,
  Logger,
  lintRunner,
  parse,
  RECOMMENDED_CONFIG,
} from "@terrazzo/parser";
import cssPlugin from "@terrazzo/plugin-css";
import { makeCSSVar } from "@terrazzo/token-tools/css";
import Color from "colorjs.io";

// The $type values Terrazzo parses: the DTCG 2025.10 types plus Terrazzo's
// boolean, link and string.
const TYPES = new Set([
  "border",
  "boolean",
  "color",
  "cubicBezier",
  "dimension",
  "duration",
  "fontFamily",
  "fontWeight",
  "gradient",
  "link",
  "number",
  "shadow",
  "string",
  "strokeStyle",
  "transition",
  "typography",
]);

// Terrazzo's recommended rules: every value well-formed for its type, and
// names in kebab case. Warnings fail the check too.
const LINT_RULES = RECOMMENDED_CONFIG;

const ALIAS = /^\{([^{}]+)\}$/;

// A logger that throws on an error, as Terrazzo's does, and also on a
// warning, so a warning fails the check. The message is plain text; the
// rules set NO_COLOR.
class StrictLogger extends Logger {
  warn(...entries) {
    super.warn(...entries);
    this.error(...entries);
  }
}

// The running command, such as "tokens check", for the closing line.
let commandName = "tokens";

// Prints each problem and a closing count, which tokens_test's output guard
// accepts as well as the success line, then exits.
function fail(problems) {
  for (const problem of problems) {
    console.error(problem);
  }
  const noun = problems.length === 1 ? "problem" : "problems";
  console.error(`${commandName}: ${problems.length} ${noun}`);
  process.exit(1);
}

function label(input) {
  const entries = Object.entries(input);
  return entries.length === 0
    ? "the default contexts"
    : entries.map(([name, context]) => `${name}=${context}`).join(", ");
}

// Reads only local files under the directory the command runs in: a $ref
// to anything else would make the result depend on the network or on files
// that aren't inputs.
function makeReq(root) {
  return async (src) => {
    if (src.protocol !== "file:") {
      throw new Error(
        `${src.href} isn't a local file; tokens read only the files in srcs`,
      );
    }
    const path = fileURLToPath(src);
    const rel = relative(root, path);
    if (rel.startsWith("..") || rel.startsWith(sep)) {
      throw new Error(`${path} is outside the tree of srcs`);
    }
    try {
      return readFileSync(path, "utf8");
    } catch {
      throw new Error(`${rel} isn't among the srcs`);
    }
  };
}

// The resolver's pieces, as written: each set and each modifier context
// with the files (or inline groups) it merges, in resolution order.
class Resolution {
  constructor(resolverPath) {
    this.root = process.cwd();
    this.path = resolverPath;
    this.rel = relative(this.root, resolve(resolverPath));
    this.url = pathToFileURL(resolve(resolverPath));
    this.problems = [];
    this.files = new Map();
    // Inline token groups, as {where, tokens}, linted like files.
    this.inline = [];
    try {
      this.doc = JSON.parse(readFileSync(resolverPath, "utf8"));
    } catch (error) {
      fail([`${this.rel}: ${error.message}`]);
    }
    if (this.doc === null || typeof this.doc !== "object") {
      fail([`${this.rel}: a resolver document is a JSON object`]);
    }
    this.order = [];
    for (const item of this.doc.resolutionOrder ?? []) {
      const entry = this.lookup(item);
      if (entry) {
        this.order.push(entry);
      }
    }
  }

  // A resolutionOrder entry, either inline or a `#/sets/x` or
  // `#/modifiers/x` reference, as {type, name, sources | contexts}.
  lookup(item) {
    let node = item;
    let name = item?.name;
    const ref = item?.$ref;
    if (typeof ref === "string") {
      const match = /^#\/(sets|modifiers)\/([^/]+)$/.exec(ref);
      if (!match) {
        return null;
      }
      node = this.doc[match[1]]?.[match[2]];
      name = match[2];
      if (!node) {
        return null;
      }
      return match[1] === "sets"
        ? {
            type: "set",
            name,
            sources: this.sources(node.sources, `set ${name}`),
          }
        : this.modifier(name, node);
    }
    if (item?.type === "modifier") {
      return this.modifier(name, item);
    }
    return {
      type: "set",
      name,
      sources: this.sources(item?.sources, `set ${name}`),
    };
  }

  modifier(name, node) {
    const contexts = {};
    for (const [context, sources] of Object.entries(node.contexts ?? {})) {
      contexts[context] = this.sources(
        sources,
        `modifier ${name}, context ${context}`,
      );
    }
    if (Object.keys(contexts).length === 0) {
      this.problems.push(
        `${this.rel}: modifier ${name} has no contexts; give it at least one`,
      );
    }
    return { type: "modifier", name, contexts, default: node.default };
  }

  // Each source as {file, tokens}: a referenced file, relative to the
  // resolver, or an inline group, attributed to the resolver itself.
  sources(list, where) {
    return (Array.isArray(list) ? list : []).map((source, i) => {
      const ref = source?.$ref;
      if (typeof ref !== "string" || ref.startsWith("#")) {
        if (!ref) {
          this.inline.push({
            where: `${where}, source ${i + 1}`,
            tokens: source,
          });
        }
        return { file: this.rel, tokens: ref ? {} : source };
      }
      const [path] = ref.split("#");
      const url = new URL(path, this.url);
      const file =
        url.protocol === "file:"
          ? relative(this.root, fileURLToPath(url))
          : url.href;
      return { file, url, tokens: this.read(file, url) };
    });
  }

  read(file, url) {
    if (!this.files.has(file)) {
      let tokens = {};
      if (url.protocol !== "file:") {
        this.problems.push(
          `${this.rel}: ${url.href} isn't a local file; tokens read only the files in srcs`,
        );
      } else if (file.startsWith("..")) {
        this.problems.push(`${this.rel}: ${file} is outside the tree of srcs`);
      } else {
        try {
          tokens = JSON.parse(readFileSync(fileURLToPath(url), "utf8"));
        } catch (error) {
          this.problems.push(
            error.code === "ENOENT"
              ? `${this.rel}: ${file} isn't among the srcs`
              : `${file}: ${error.message}`,
          );
        }
      }
      this.files.set(file, tokens);
    }
    return this.files.get(file);
  }

  // Every permutation: the product of each modifier's contexts.
  permutations() {
    let inputs = [{}];
    for (const entry of this.order) {
      if (entry.type !== "modifier") {
        continue;
      }
      const next = [];
      for (const input of inputs) {
        for (const context of Object.keys(entry.contexts)) {
          next.push({ ...input, [entry.name]: context });
        }
      }
      inputs = next;
    }
    return inputs;
  }

  // The tokens one permutation defines: id -> {file, value, type}, the last
  // file in resolution order winning, as the resolver merges them.
  tokens(input) {
    const tokens = new Map();
    for (const entry of this.order) {
      const sources =
        entry.type === "set"
          ? entry.sources
          : entry.contexts[input[entry.name]];
      for (const source of sources ?? []) {
        walk(source.tokens, [], undefined, (id, token, type) => {
          tokens.set(id, { file: source.file, value: token.$value, type });
        });
      }
    }
    return tokens;
  }
}

// Calls visit(id, token, inheritedType) for each token (an object with
// $value) in a group, depth first.
function walk(group, path, type, visit) {
  if (group === null || typeof group !== "object" || Array.isArray(group)) {
    return;
  }
  const groupType = typeof group.$type === "string" ? group.$type : type;
  if ("$value" in group) {
    visit(path.join("."), group, groupType);
    return;
  }
  for (const [key, child] of Object.entries(group)) {
    if (!key.startsWith("$")) {
      walk(child, [...path, key], groupType, visit);
    }
  }
}

// The ids a value refers to through curly-brace aliases, at any depth.
function aliasesIn(value, found = []) {
  if (typeof value === "string") {
    const match = ALIAS.exec(value);
    if (match) {
      found.push(match[1]);
    }
  } else if (value !== null && typeof value === "object") {
    for (const child of Object.values(value)) {
      aliasesIn(child, found);
    }
  }
  return found;
}

// Problems reported once per file and message, with the permutations that
// show them.
class Problems {
  constructor() {
    this.byKey = new Map();
  }

  add(file, message, input) {
    const key = `${file}\u0000${message}`;
    if (!this.byKey.has(key)) {
      this.byKey.set(key, { file, message, inputs: [] });
    }
    if (input) {
      this.byKey.get(key).inputs.push(input);
    }
  }

  list(total) {
    return [...this.byKey.values()].map(({ file, message, inputs }) => {
      const where =
        inputs.length === 0 || inputs.length === total
          ? ""
          : ` (when ${inputs.map(label).join("; ")})`;
      return `${file}: ${message}${where}`;
    });
  }

  get size() {
    return this.byKey.size;
  }
}

// Each token file through Terrazzo's parser and linter on its own, without
// resolving aliases, which may point into other files: a schema or type
// error then names the file it is in.
async function checkFiles(resolution, config) {
  const problems = [];
  const req = makeReq(resolution.root);
  for (const [file, tokens] of resolution.files) {
    if (file.startsWith("..") || /^[a-z]+:/.test(file)) {
      continue;
    }
    if (Object.keys(tokens).length === 0) {
      continue;
    }
    const url = pathToFileURL(join(resolution.root, file));
    try {
      await parse([{ filename: url, src: readFileSync(url, "utf8") }], {
        config,
        logger: new StrictLogger(),
        req,
        resolveAliases: false,
      });
    } catch (error) {
      problems.push(`${file}: ${error.message}`);
    }
  }
  // The resolver's inline groups, each parsed as a document of its own and
  // named by where it sits in the resolver.
  for (const [i, { where, tokens }] of resolution.inline.entries()) {
    if (tokens === null || typeof tokens !== "object") {
      problems.push(`${resolution.rel}: ${where} isn't a token group`);
      continue;
    }
    try {
      await parse(
        [
          {
            filename: new URL(`${resolution.url.href}.inline-${i + 1}.json`),
            src: JSON.stringify(tokens),
          },
        ],
        { config, logger: new StrictLogger(), req, resolveAliases: false },
      );
    } catch (error) {
      problems.push(`${resolution.rel} (${where}): ${error.message}`);
    }
  }
  return problems;
}

// The checks that name a file: each token's $type, each alias's target,
// cycles, and tokens that one permutation defines and another lacks.
function checkStructure(resolution, inputs) {
  const problems = new Problems();
  const perInput = inputs.map((input) => resolution.tokens(input));
  // Each id, with the permutations that define it.
  const definedIn = new Map();
  perInput.forEach((tokens, i) => {
    for (const id of tokens.keys()) {
      if (!definedIn.has(id)) {
        definedIn.set(id, []);
      }
      definedIn.get(id).push(i);
    }
  });

  // A token one permutation lacks comes first: the aliases to it that then
  // fail follow from it.
  perInput.forEach((tokens, i) => {
    for (const [id, defining] of definedIn) {
      if (!tokens.has(id)) {
        problems.add(...missing(resolution, id, i, inputs, perInput, defining));
      }
    }
  });
  perInput.forEach((tokens, i) => {
    const input = inputs[i];
    for (const [id, token] of tokens) {
      const isAlias =
        typeof token.value === "string" && ALIAS.test(token.value);
      if (token.type !== undefined && !TYPES.has(token.type)) {
        problems.add(
          token.file,
          `${id} has $type ${JSON.stringify(token.type)}, which isn't a DTCG type`,
          input,
        );
      } else if (token.type === undefined && !isAlias) {
        problems.add(
          token.file,
          `${id} has no $type, on the token or a group above it`,
          input,
        );
      }
      for (const ref of aliasesIn(token.value)) {
        if (!tokens.has(ref)) {
          problems.add(
            token.file,
            `${id} refers to {${ref}}, which no token defines`,
            input,
          );
        }
      }
    }
    for (const cycle of cycles(tokens)) {
      const first = tokens.get(cycle[0]);
      problems.add(
        first.file,
        `alias cycle: ${cycle.join(" -> ")} -> ${cycle[0]}`,
        input,
      );
    }
  });
  return problems.list(inputs.length);
}

// Who to blame for a token that permutation i lacks. When a permutation
// that differs from it in one modifier defines the token, the blame goes
// to this permutation's files for that modifier's context.
function missing(resolution, id, i, inputs, perInput, defining) {
  const input = inputs[i];
  for (const j of defining) {
    const other = inputs[j];
    const differing = Object.keys(input).filter((n) => input[n] !== other[n]);
    if (differing.length !== 1) {
      continue;
    }
    const [name] = differing;
    const entry = resolution.order.find(
      (e) => e.type === "modifier" && e.name === name,
    );
    const files = [...new Set(entry.contexts[input[name]].map((s) => s.file))];
    return [
      files.join(", ") || resolution.rel,
      `${name} ${input[name]} lacks ${id}, which ${perInput[j].get(id).file} defines for ${name} ${other[name]}`,
      input,
    ];
  }
  const j = defining[0];
  return [
    resolution.rel,
    `${id} is missing, which ${perInput[j].get(id).file} defines when ${label(inputs[j])}`,
    input,
  ];
}

// The alias cycles among tokens, each as the ids around it, found once.
function cycles(tokens) {
  const found = [];
  const done = new Set();
  for (const start of tokens.keys()) {
    const path = [];
    const onPath = new Map();
    let id = start;
    while (id !== undefined && tokens.has(id) && !done.has(id)) {
      if (onPath.has(id)) {
        found.push(path.slice(onPath.get(id)));
        break;
      }
      onPath.set(id, path.length);
      path.push(id);
      const value = tokens.get(id).value;
      const match = typeof value === "string" ? ALIAS.exec(value) : null;
      id = match?.[1];
    }
    for (const seen of path) {
      done.add(seen);
    }
  }
  return found;
}

// Loads the resolver with Terrazzo and resolves every permutation, after
// the checks that name a file. Returns what tokens_css builds from.
async function load(resolverPath) {
  const resolution = new Resolution(resolverPath);
  const cwd = pathToFileURL(`${resolution.root}/`);
  const config = defineConfig(
    { lint: { rules: LINT_RULES } },
    { cwd, logger: new StrictLogger() },
  );
  const inputs = resolution.permutations();
  const problems = [
    ...resolution.problems,
    ...(await checkFiles(resolution, config)),
  ];
  if (problems.length === 0) {
    problems.push(...checkStructure(resolution, inputs));
  }
  if (problems.length > 0) {
    fail(problems);
  }

  config.permutationLimit = Math.max(config.permutationLimit, inputs.length);
  const logger = new StrictLogger();
  let parsed;
  try {
    parsed = await parse(
      [{ filename: resolution.url, src: readFileSync(resolverPath, "utf8") }],
      { config, logger, req: makeReq(resolution.root), skipLint: true },
    );
  } catch (error) {
    fail([`${resolution.rel}: ${error.message}`]);
  }
  if (!parsed.resolver?.source) {
    fail([`${resolution.rel}: not a DTCG resolver document`]);
  }
  const resolved = [];
  for (const input of inputs) {
    try {
      resolved.push({ input, tokens: parsed.resolver.apply(input) });
    } catch (error) {
      problems.push(
        `${resolution.rel}: when ${label(input)}: ${error.message}`,
      );
    }
  }
  if (problems.length > 0) {
    fail(problems);
  }
  return { resolution, config, parsed, resolved };
}

// DTCG color spaces by colorjs.io's ids, where the two differ.
const COLOR_SPACE_IDS = {
  "a98-rgb": "a98rgb",
  "display-p3": "p3",
  "prophoto-rgb": "prophoto",
  xyz: "xyz-d65",
};

function toColor(value) {
  return new Color(
    COLOR_SPACE_IDS[value.colorSpace] ?? value.colorSpace,
    value.components,
    value.alpha ?? 1,
  );
}

// A translucent foreground as it shows over an opaque background: each
// sRGB channel mixed by the foreground's alpha, as a browser composites.
function composite(foreground, background) {
  const fg = toColor(foreground).to("srgb").toGamut();
  const bg = toColor(background).to("srgb").toGamut();
  const a = fg.alpha;
  return {
    colorSpace: "srgb",
    components: fg.coords.map((c, i) => a * c + (1 - a) * bg.coords[i]),
    alpha: 1,
  };
}

// One contrast pair in one permutation, through Terrazzo's
// a11y/min-contrast rule: the problem, or null when the pair passes.
// WCAG 2's ratio is for opaque colors, and the rule reads alpha as 1, so a
// translucent foreground is first composited over the background. A
// translucent background is refused: what shows through it isn't known.
async function contrastProblem(pair, level, input, tokens, sources) {
  const where = `contrast pair ${pair.foreground} on ${pair.background}`;
  for (const id of [pair.foreground, pair.background]) {
    if (tokens[id]?.$type !== "color") {
      return `${where}: ${id} isn't a color token`;
    }
  }
  const bgAlpha = tokens[pair.background].$value.alpha ?? 1;
  if (bgAlpha < 1) {
    return `${where}: ${pair.background} has alpha ${bgAlpha}, and a translucent background's contrast depends on what lies behind it; pair the foreground with an opaque background (when ${label(input)})`;
  }
  const fgAlpha = tokens[pair.foreground].$value.alpha ?? 1;
  let over = "";
  if (fgAlpha < 1) {
    tokens = {
      ...tokens,
      [pair.foreground]: {
        ...tokens[pair.foreground],
        $value: composite(
          tokens[pair.foreground].$value,
          tokens[pair.background].$value,
        ),
      },
    };
    over = ` (${pair.foreground} at alpha ${fgAlpha}, composited over ${pair.background})`;
  }
  const config = defineConfig(
    {
      lint: {
        rules: {
          "a11y/min-contrast": [
            "error",
            {
              level,
              pairs: [
                {
                  foreground: pair.foreground,
                  background: pair.background,
                  largeText: Boolean(pair.large_text),
                },
              ],
            },
          ],
        },
      },
    },
    { cwd: pathToFileURL(`${process.cwd()}/`) },
  );
  const reports = [];
  const logger = new Logger();
  logger.error = (...entries) => reports.push(...entries);
  await lintRunner({ tokens, sources, config, logger });
  // The rule reports "Pair 1 failed; expected 4.5, got 3.18 (AA)", then the
  // runner a count, labelled "lint".
  const report = reports.find((r) => r.label !== "lint");
  if (!report) {
    return null;
  }
  const detail = report.message.replace(/^Pair \d+ failed; /, "");
  const size = pair.large_text ? " for large text" : "";
  return `${where} fails WCAG 2 ${level}${size}: ${detail}${over} (when ${label(input)})`;
}

// Two-space JSON with each array of numbers on one line, as Biome and
// Prettier lay out the palette files' components, so a formatter run over
// the committed files leaves them as generated.
function formatJson(value) {
  return JSON.stringify(value, null, 2).replace(
    /\[\s+([-\d.e,\s]+?)\s+\]/g,
    (_, items) => `[${items.split(/,\s+/).join(", ")}]`,
  );
}

// tokens_test.
async function check(resolverPath, options) {
  const { resolution, parsed, resolved } = await load(resolverPath);
  const pairs = options.contrast ?? [];
  const level = options.contrast_level ?? "AA";
  const problems = [];
  for (const { input, tokens } of resolved) {
    for (const pair of pairs) {
      const problem = await contrastProblem(
        pair,
        level,
        input,
        tokens,
        parsed.sources,
      );
      if (problem) {
        problems.push(`${resolution.rel}: ${problem}`);
      }
    }
  }
  if (problems.length > 0) {
    fail(problems);
  }
  const count = Object.keys(resolved[0].tokens).length;
  console.log(
    `tokens check: ${count} tokens, ${resolved.length} permutations, ${resolution.files.size} files, ${pairs.length} contrast pairs`,
  );
}

// What a token contributes to CSS in one permutation: the token it aliases
// directly (its var()), the tokens its parts alias, and its resolved value.
// Two permutations that agree on this need no second declaration.
function signature(token) {
  return JSON.stringify([
    token.aliasChain?.[0] ?? null,
    token.partialAliasOf ?? null,
    token.$value,
  ]);
}

// The ids whose signature changes when only `name` changes: compared
// between every two permutations that differ in that modifier alone.
function varying(resolved, name) {
  const ids = new Set();
  for (const a of resolved) {
    for (const b of resolved) {
      const others = Object.keys(a.input).filter((n) => n !== name);
      if (
        a.input[name] === b.input[name] ||
        others.some((n) => a.input[n] !== b.input[n])
      ) {
        continue;
      }
      for (const [id, token] of Object.entries(a.tokens)) {
        if (signature(token) !== signature(b.tokens[id])) {
          ids.add(id);
        }
      }
    }
  }
  return ids;
}

const scaleOf = (id) => id.slice(0, id.lastIndexOf("."));

// The palette scales tokens_css keeps: those a token outside `palette`
// refers to, then those a token in a kept scale refers to, until no more
// are added, in any permutation. A token's aliasChain holds its whole chain
// of aliases, but partialAliasOf, for the parts of a composite value, only
// the tokens they name, so their own aliases come from the next round.
// Every var() a kept token writes then names a kept token.
function keptScales(resolved, palette) {
  const scales = new Set();
  const refs = (token) => {
    const ids = [...(token.aliasChain ?? [])];
    const add = (value) => {
      if (typeof value === "string") {
        ids.push(value);
      } else if (value !== null && typeof value === "object") {
        for (const child of Object.values(value)) {
          add(child);
        }
      }
    };
    add(token.partialAliasOf ?? {});
    return ids.filter((id) => inGroup(id, palette)).map(scaleOf);
  };
  const keeps = (id) => !inGroup(id, palette) || scales.has(scaleOf(id));
  let size = -1;
  while (scales.size !== size) {
    size = scales.size;
    for (const { tokens } of resolved) {
      for (const [id, token] of Object.entries(tokens)) {
        if (keeps(id)) {
          for (const scale of refs(token)) {
            scales.add(scale);
          }
        }
      }
    }
  }
  return scales;
}

function inGroup(id, group) {
  return group !== "" && (id === group || id.startsWith(`${group}.`));
}

const SAFE_NAME = /^[A-Za-z0-9_-]+$/;

// tokens_css: the blocks, in cascade order, each with the permutation it
// declares and the ids it declares.
//
//   :root                                       defaults, every token
//   [data-<theme>="T"]                          each theme, its theme tokens
//   @media dark :root:not([data-<mode>="light"])        default theme, dark
//   @media dark [data-<theme>="T"]:not([data-<mode>="light"])   T, dark
//   [data-<mode>="light"], [data-<mode>="dark"]         default theme
//   [data-<theme>="T"][data-<mode>="light" | "dark"]    T
//
// Selectors of equal specificity follow source order, so a later block
// wins: a theme over the defaults, a theme's dark over the default dark,
// and an explicit mode on the element over the media query, which its
// :not() also turns off.
function cssBlocks(resolution, resolved, options) {
  const problems = [];
  const modifiers = resolution.order.filter((e) => e.type === "modifier");
  const byName = new Map(modifiers.map((m) => [m.name, m]));
  const themeName = options.theme_modifier;
  const modeName = options.mode_modifier;
  const { light, dark } = options;
  for (const m of modifiers) {
    if (m.name !== themeName && m.name !== modeName) {
      problems.push(
        `modifier ${m.name} is neither the theme modifier (${themeName}) nor the mode modifier (${modeName}); tokens_css builds only those two`,
      );
    }
    if (typeof m.default !== "string") {
      problems.push(
        `modifier ${m.name} has no default context, which :root needs`,
      );
    }
    for (const context of Object.keys(m.contexts)) {
      if (!SAFE_NAME.test(context)) {
        problems.push(
          `modifier ${m.name}: context ${JSON.stringify(context)} can't be an attribute value; use letters, digits, - and _`,
        );
      }
    }
  }
  const mode = byName.get(modeName);
  if (mode) {
    const contexts = Object.keys(mode.contexts).sort();
    if (contexts.join() !== [dark, light].sort().join()) {
      problems.push(
        `modifier ${modeName} has contexts ${contexts.join(", ")}; tokens_css needs exactly ${light} and ${dark}`,
      );
    } else if (mode.default !== light) {
      problems.push(
        `modifier ${modeName}'s default is ${mode.default}; tokens_css needs ${light}`,
      );
    }
  }
  if (problems.length > 0) {
    fail(problems.map((p) => `${resolution.rel}: ${p}`));
  }

  const theme = byName.get(themeName);
  const themes = theme ? Object.keys(theme.contexts) : [];
  const defaults = Object.fromEntries(
    modifiers.map((m) => [m.name, m.default]),
  );
  const ids = Object.keys(resolved[0].tokens).sort();
  const usedScales = keptScales(resolved, options.palette);
  const keep = ids.filter(
    (id) => !inGroup(id, options.palette) || usedScales.has(scaleOf(id)),
  );
  const themeIds = theme ? varying(resolved, themeName) : new Set();
  const modeIds = mode ? varying(resolved, modeName) : new Set();
  const only = (set) => keep.filter((id) => set.has(id));

  const t = `data-${themeName}`;
  const m = `data-${modeName}`;
  const notLight = `:not([${m}="${light}"])`;
  const media = "@media (prefers-color-scheme: dark)";
  const blocks = [{ selector: ":root", input: defaults, ids: keep }];
  for (const name of themes) {
    blocks.push({
      selector: `[${t}="${name}"]`,
      input: { ...defaults, [themeName]: name },
      ids: only(themeIds),
    });
  }
  if (mode) {
    const darkInput = { ...defaults, [modeName]: dark };
    blocks.push({
      media,
      selector: `:root${notLight}`,
      input: darkInput,
      ids: only(modeIds),
    });
    for (const name of themes) {
      blocks.push({
        media,
        selector: `[${t}="${name}"]${notLight}`,
        input: { ...darkInput, [themeName]: name },
        ids: only(modeIds),
      });
    }
    for (const context of [light, dark]) {
      blocks.push({
        selector: `[${m}="${context}"]`,
        input: { ...defaults, [modeName]: context },
        ids: only(modeIds),
      });
    }
    for (const name of themes) {
      for (const context of [light, dark]) {
        blocks.push({
          selector: `[${t}="${name}"][${m}="${context}"]`,
          input: { ...defaults, [themeName]: name, [modeName]: context },
          ids: only(modeIds),
        });
      }
    }
  }
  return blocks.filter((b) => b.ids.length > 0);
}

// tokens_css.
async function cssCommand(resolverPath, outPath, options) {
  const { resolution, parsed, resolved } = await load(resolverPath);
  const blocks = cssBlocks(resolution, resolved, options);
  for (const block of blocks) {
    for (const id of block.ids) {
      // plugin-css matches ids as globs.
      if (/[*?[\]{}!]/.test(id)) {
        fail([
          `${resolution.rel}: token id ${id} has a glob character, which tokens_css can't select`,
        ]);
      }
    }
  }
  const permutations = blocks.map((block) => ({
    input: block.input,
    include: block.ids,
    prepare: block.media
      ? (css) => `${block.media} {\n  ${block.selector} {\n    ${css}\n  }\n}`
      : (css) => `${block.selector} {\n  ${css}\n}`,
  }));
  const filename = "tokens.css";
  const config = defineConfig(
    {
      lint: { rules: {} },
      plugins: [
        cssPlugin({
          filename,
          permutations,
          // Terrazzo's own name, `--color-text`, behind the prefix:
          // `--tbhb-color-text`. Aliases' var()s use the same names.
          ...(options.prefix
            ? {
                variableName: (token) =>
                  makeCSSVar(token.id, { prefix: options.prefix }),
              }
            : {}),
        }),
      ],
    },
    { cwd: pathToFileURL(`${resolution.root}/`), logger: new StrictLogger() },
  );
  config.permutationLimit = Math.max(config.permutationLimit, resolved.length);
  let result;
  try {
    result = await build(parsed.tokens, {
      sources: parsed.sources,
      config,
      resolver: parsed.resolver,
      logger: new StrictLogger(),
    });
  } catch (error) {
    fail([`${resolution.rel}: ${error.message}`]);
  }
  const css = result.outputFiles.find((f) => f.filename === filename);
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, css.contents);
}

// Radix Colors' exports, as a plain object to look scales up in by name.
const radix = { ...radixColors };

// Radix Colors' solid scales: each export without a suffix that has a
// Dark, P3 and DarkP3 partner (`blue`, not `blueA` or `blueDark`).
function radixScales() {
  return Object.keys(radix)
    .filter((name) =>
      ["Dark", "P3", "DarkP3", "A", "DarkA", "P3A", "DarkP3A"].every(
        (suffix) => `${name}${suffix}` in radix,
      ),
    )
    .sort();
}

const round = (value, digits) => Number(value.toFixed(digits));

// One scale in one mode, as a DTCG group palette.<scale> of the solid steps
// 1 to 12 and the alpha steps a1 to a12: Radix's Display P3 value converted
// to an oklch color, with Radix's sRGB hex as the fallback. An alpha step
// keeps the P3 value's alpha, and its hex drops the sRGB value's alpha
// byte, since DTCG's hex is six digits. Lightness and chroma keep four
// decimals, hue two and alpha three, so the output is stable. An
// achromatic step, which has no hue, gets hue 0: DTCG allows "none" there,
// but Terrazzo's valid-color rule rejects it, and with chroma 0 the hue
// changes nothing.
function radixPalette(scale, mode, version) {
  const key = mode === "dark" ? `${scale}Dark` : scale;
  const group = {
    $type: "color",
    $description: `Radix Colors ${scale}, ${mode}, from @radix-ui/colors ${version}`,
  };
  const color = (p3, hex) => {
    const oklch = new Color(p3).to("oklch");
    const [l, c, h] = oklch.coords;
    const alpha = round(Number(oklch.alpha), 3);
    return {
      $value: {
        colorSpace: "oklch",
        components: [
          round(l, 4),
          round(c, 4),
          h === null || Number.isNaN(h) ? 0 : round(h, 2),
        ],
        ...(alpha < 1 ? { alpha } : {}),
        hex: hex.slice(0, 7),
      },
    };
  };
  for (let step = 1; step <= 12; step += 1) {
    group[step] = color(
      radix[`${key}P3`][`${scale}${step}`],
      radix[key][`${scale}${step}`],
    );
  }
  for (let step = 1; step <= 12; step += 1) {
    group[`a${step}`] = color(
      radix[`${key}P3A`][`${scale}A${step}`],
      radix[`${key}A`][`${scale}A${step}`],
    );
  }
  return { palette: { [scale]: group } };
}

// REUSE's sidecar for each generated file: the values are Radix's.
const RADIX_LICENSE =
  "SPDX-FileCopyrightText: 2021 Radix\nSPDX-License-Identifier: MIT\n";

// radix_palettes.
function radixCommand(outDir, scales) {
  const known = radixScales();
  const unknown = scales.filter((s) => !known.includes(s));
  if (unknown.length > 0) {
    fail([
      `radix_palettes: ${unknown.join(", ")} isn't a Radix Colors scale; the scales are ${known.join(", ")}`,
    ]);
  }
  const { version } = JSON.parse(
    readFileSync(
      join(
        dirname(fileURLToPath(import.meta.resolve("@radix-ui/colors"))),
        "package.json",
      ),
      "utf8",
    ),
  );
  mkdirSync(outDir, { recursive: true });
  for (const scale of scales) {
    for (const mode of ["light", "dark"]) {
      const file = join(outDir, `${scale}.${mode}.tokens.json`);
      writeFileSync(
        file,
        `${formatJson(radixPalette(scale, mode, version))}\n`,
      );
      writeFileSync(`${file}.license`, RADIX_LICENSE);
    }
  }
}

main();

async function main() {
  const [command, ...args] = process.argv.slice(2);
  commandName = `tokens ${command}`;
  switch (command) {
    case "check":
      await check(args[0], JSON.parse(args[1] ?? "{}"));
      break;
    case "css": {
      // Run in the tree of srcs; the output path is the caller's.
      const out = resolve(args[2]);
      process.chdir(args[0]);
      await cssCommand(args[1], out, {
        theme_modifier: "theme",
        mode_modifier: "mode",
        light: "light",
        dark: "dark",
        palette: "palette",
        ...JSON.parse(args[3] ?? "{}"),
      });
      break;
    }
    case "radix":
      radixCommand(args[0], args.slice(1));
      break;
    case "scales":
      console.log(radixScales().join("\n"));
      break;
    default:
      console.error(`launch.mjs: unknown command ${command}`);
      process.exitCode = 2;
  }
}
