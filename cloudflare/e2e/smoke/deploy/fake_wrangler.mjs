// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Stands in for wrangler in deploy_test. Each call is recorded in FAKE_LOG
// with the environment wrangler would see. The deployment lives in
// FAKE_STATE (a JSON list of versions, or absent for a Worker that doesn't
// exist yet): `deployments status` reads it and `versions deploy` writes it.
//
// FAKE_UPLOAD=fail|silent makes the upload exit 1 or succeed without its
// output record; FAKE_DEPLOY_FAIL lists deploys that fail, each its version
// specs joined by spaces, the lists separated by commas; FAKE_UPLOAD_SLEEP=<ms> pauses the upload after
// writing FAKE_STARTED. FAKE_DEPLOY_CODE prints an API error on stderr for
// the failing deploys; FAKE_DEPLOY_FAILURES limits failures per version spec.
import {
  appendFileSync,
  existsSync,
  readFileSync,
  statSync,
  writeFileSync,
} from "node:fs";

const args = process.argv.slice(2);
const command = args.slice(0, 2).join(" ");
const flag = (name) => args[args.indexOf(name) + 1];
const env = process.env;
const entry = {
  command,
  args,
  cwd: process.cwd(),
  env: Object.fromEntries(
    [
      "HOME",
      "USERPROFILE",
      "XDG_CONFIG_HOME",
      "WRANGLER_LOG_PATH",
      "WRANGLER_LOG",
      "WRANGLER_LOG_SANITIZE",
      "WRANGLER_HIDE_BANNER",
      "CLOUDFLARE_API_KEY",
      "CLOUDFLARE_EMAIL",
      "CF_API_KEY",
      "CF_API_TOKEN",
      "CLOUDFLARE_API_TOKEN",
    ].map((name) => [name, env[name] ?? null]),
  ),
};
const log = () => appendFileSync(env.FAKE_LOG, `${JSON.stringify(entry)}\n`);
const failing = (env.FAKE_DEPLOY_FAIL ?? "").split(",").filter(Boolean);

if (command === "deployments status") {
  log();
  if (!existsSync(env.FAKE_STATE)) {
    console.error("The Worker smoke-stg has no deployments.");
    process.exit(1);
  }
  console.log(
    JSON.stringify({ versions: JSON.parse(readFileSync(env.FAKE_STATE)) }),
  );
} else if (command === "versions upload") {
  const file = flag("--secrets-file");
  entry.secretsFile = file;
  entry.secrets = JSON.parse(readFileSync(file, "utf8"));
  entry.secretsMode = (statSync(file).mode & 0o777).toString(8);
  log();
  if (env.FAKE_UPLOAD_SLEEP) {
    writeFileSync(env.FAKE_STARTED, "upload");
    Atomics.wait(
      new Int32Array(new SharedArrayBuffer(4)),
      0,
      0,
      Number(env.FAKE_UPLOAD_SLEEP),
    );
  }
  if (env.FAKE_UPLOAD === "fail") {
    process.exit(1);
  }
  if (env.FAKE_UPLOAD !== "silent") {
    writeFileSync(
      env.WRANGLER_OUTPUT_FILE_PATH,
      `${JSON.stringify({ type: "version-upload", worker_name: "smoke-stg", version_id: env.FAKE_NEW })}\n`,
    );
  }
} else if (command === "versions deploy") {
  log();
  const specs = args.slice(2, args.indexOf("--yes"));
  if (failing.includes(specs.join(" "))) {
    const attempts = readFileSync(env.FAKE_LOG, "utf8")
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line))
      .filter(
        (call) =>
          call.command === command &&
          call.args.slice(2, call.args.indexOf("--yes")).join(" ") ===
            specs.join(" "),
      ).length;
    if (attempts <= Number(env.FAKE_DEPLOY_FAILURES ?? Infinity)) {
      if (env.FAKE_DEPLOY_CODE) {
        const code =
          env.FAKE_DEPLOY_CODE === "none"
            ? ""
            : ` \u001b[33m[code: ${env.FAKE_DEPLOY_CODE}]\u001b[0m`;
        console.error(
          `A request to the Cloudflare API failed.\n  The requested Worker version could not be found.${code}`,
        );
      }
      process.exit(1);
    }
  }
  writeFileSync(
    env.FAKE_STATE,
    JSON.stringify(
      specs.map((s) => {
        const [id, pct] = s.split("@");
        return { version_id: id, percentage: Number.parseInt(pct, 10) };
      }),
    ),
  );
}
