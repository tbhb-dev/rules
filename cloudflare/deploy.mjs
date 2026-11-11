// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// worker_deploy's launcher (private/worker.bzl). Deploys a built bundle as
// a new Worker version and moves traffic to it only after its tests pass:
//
// 1. Reads the live deployment, which must be one version at 100%, and
//    refuses a Durable Object migration the config declares that the live
//    script hasn't applied: `versions upload` can't apply one, so it needs
//    a one-off plain `wrangler deploy` first.
// 2. Uploads the bundle as a new version, with the Worker's secrets.
// 3. Deploys it at 0% beside the live version, retrying error 100146
//    after 5, 10 and 20 seconds while the new version becomes visible.
// 4. Runs the pre-deploy tests against the new version, through the
//    Cloudflare-Workers-Version-Overrides header.
// 5. Checks the deployment is still the one step 3 made, moves the new
//    version to 100%, and runs the post-deploy tests against the live URL.
//    A failing test of either phase is rerun for up to a minute, since a
//    deployment takes effect a few seconds after the API returns.
// 6. Puts the previous version back at 100% when anything fails after
//    step 3 (a post-deploy test only when rollback is on), and exits
//    non-zero.
//
// SIGINT, SIGTERM and SIGHUP (a Ctrl-C, a cancelled workflow) count as a
// failure: the signal goes on to the running child's process group, then
// the restore and the cleanup run, and no signal interrupts the restore.
// Children run asynchronously so the handlers can run while one is busy,
// and a child that outlives its timeout gets SIGTERM, then SIGKILL. A
// signal also ends the pause between test attempts. The rules_js launcher
// passes on SIGINT and SIGTERM but not SIGHUP. SIGKILL can't be handled;
// after one, check the deployment by hand.
//
// The settings come from the macro as TBHB_DEPLOY; the Cloudflare
// credentials from CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID, and each
// secret's value from the variable the macro names for it.
import { spawn as spawnChild } from "node:child_process";
import {
  appendFileSync,
  cpSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { stripVTControlCharacters } from "node:util";

const here = dirname(fileURLToPath(import.meta.url));

// A failure the deploy reports; anything else is a crash.
class Failure extends Error {}

function fail(message) {
  throw new Failure(message);
}

function exitWith(message) {
  console.error(`worker_deploy: ${message}`);
  process.exit(1);
}

// The running child, which a signal or a timeout stops, and whether the
// restore is running, which nothing interrupts.
let current = null;
let restoring = false;
let interrupted = null;
// Ends the pause between test attempts, while there is one.
let wake = null;
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(signal, () => {
    interrupted ??= signal;
    wake?.();
    if (!restoring && current !== null) {
      stop(current, signal);
    }
  });
}

function checkInterrupted() {
  if (interrupted !== null && !restoring) {
    fail(`interrupted by ${interrupted}`);
  }
}

// Stops a child and everything it started: each child leads its own
// process group on POSIX, and Windows has taskkill for the tree.
function stop(child, signal) {
  if (child.exitCode !== null || child.signalCode !== null) {
    return;
  }
  if (process.platform === "win32") {
    spawnChild("taskkill", ["/pid", String(child.pid), "/t", "/f"], {
      stdio: "ignore",
    });
    return;
  }
  try {
    process.kill(-child.pid, signal);
  } catch {
    // The group is already gone.
  }
}

const settings = JSON.parse(process.env.TBHB_DEPLOY ?? "null");
if (settings === null) {
  exitWith("TBHB_DEPLOY is unset; run this through a worker_deploy target");
}
if (/[\r\n]/.test(settings.url)) {
  exitWith("the url has a line break");
}
const runfiles = process.env.JS_BINARY__RUNFILES ?? process.env.RUNFILES_DIR;
const workspace = process.env.JS_BINARY__WORKSPACE ?? "_main";

function runfile(rootpath) {
  return resolve(join(runfiles, workspace, rootpath));
}

for (const name of ["CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID"]) {
  if (!process.env[name]) {
    exitWith(`${name} is unset`);
  }
}
const secrets = {};
for (const [secret, variable] of Object.entries(settings.secrets)) {
  const value = process.env[variable];
  if (!value) {
    exitWith(`${variable}, the value of the Worker secret ${secret}, is unset`);
  }
  secrets[secret] = value;
}

// Variables no child sees. wrangler prefers a global API key
// (CLOUDFLARE_API_KEY with CLOUDFLARE_EMAIL, or their CF_ names) over
// CLOUDFLARE_API_TOKEN, so a shell holding one would deploy with it, and
// WRANGLER_LOG=debug prints request bodies.
const NEVER = [
  "CF_ACCOUNT_ID",
  "CF_API_KEY",
  "CF_API_TOKEN",
  "CF_EMAIL",
  "CLOUDFLARE_API_KEY",
  "CLOUDFLARE_EMAIL",
  "WRANGLER_LOG",
];
// The test executables get none of the credentials unless pass_env names
// them.
const CREDENTIALS = [
  "CLOUDFLARE_ACCOUNT_ID",
  "CLOUDFLARE_API_TOKEN",
  ...Object.values(settings.secrets),
];

function without(env, names) {
  const copy = { ...env };
  for (const name of names) {
    delete copy[name];
  }
  return copy;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// wrangler runs in a scratch directory that holds its home, config, logs
// and the secrets file, none of which outlive this process.
const scratch = mkdtempSync(
  join(process.env.RUNNER_TEMP || tmpdir(), "worker-deploy-"),
);
const config = runfile(settings.config);
// Tests point this at a stand-in for wrangler; outside a test it's ignored.
const wranglerBin =
  (process.env.TEST_TMPDIR && process.env.TBHB_DEPLOY_WRANGLER) ||
  join(here, "node_modules", "wrangler", "bin", "wrangler.js");
const wranglerTimeout = settings.wrangler_timeout * 1000;
const testTimeout = settings.test_timeout * 1000;
let calls = 0;

// A deployment takes effect a few seconds after the API returns, so the old
// version can keep answering after `wrangler versions deploy` has exited. A
// failing test is rerun, RETRY_PAUSE after each failure, until it passes or
// SETTLE has passed since its phase began. Tests set
// TBHB_DEPLOY_SETTLE_SCALE to shrink or stretch both; outside a test it's
// ignored.
const scale =
  (process.env.TEST_TMPDIR && Number(process.env.TBHB_DEPLOY_SETTLE_SCALE)) ||
  1;
const SETTLE = 60_000 * scale;
const RETRY_PAUSE = 5_000 * scale;

// Milliseconds a timed-out child gets between SIGTERM and SIGKILL.
const GRACE = 10_000;

// Runs a child to completion and resolves with its status, signal, any
// start error, whether it timed out, and any captured output. Windows
// runs a .bat or .cmd file only through cmd.exe, and Node refuses to start
// one without a shell; such a file gets no arguments, so nothing needs
// quoting for cmd.exe.
function spawn(
  file,
  args,
  { timeout, capture = false, captureStderr = false, ...options },
) {
  let command = file;
  let argv = args;
  if (process.platform === "win32" && /\.(bat|cmd)$/i.test(file)) {
    if (args.length > 0) {
      throw new Error(`spawn: ${file} takes no arguments`);
    }
    command = process.env.ComSpec ?? "cmd.exe";
    argv = ["/d", "/s", "/c", `""${file}""`];
    options.windowsVerbatimArguments = true;
  }
  return new Promise((done) => {
    const child = spawnChild(command, argv, {
      ...options,
      detached: process.platform !== "win32",
      stdio: [
        "ignore",
        capture ? "pipe" : "inherit",
        captureStderr ? "pipe" : "inherit",
      ],
    });
    current = child;
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    child.stdout?.setEncoding("utf8").on("data", (data) => {
      stdout += data;
    });
    child.stderr?.setEncoding("utf8").on("data", (data) => {
      stderr += data;
      process.stderr.write(data);
    });
    let kill = null;
    const timer = setTimeout(() => {
      timedOut = true;
      stop(child, "SIGTERM");
      kill = setTimeout(() => stop(child, "SIGKILL"), GRACE);
    }, timeout);
    const finish = (result) => {
      clearTimeout(timer);
      clearTimeout(kill);
      current = null;
      done({ ...result, timedOut, stdout, stderr });
    };
    child.on("error", (error) => finish({ status: null, signal: null, error }));
    child.on("close", (status, signal) =>
      finish({ status, signal, error: null }),
    );
  });
}

function describe(result) {
  if (result.timedOut) {
    return "timed out";
  }
  if (result.error) {
    return `couldn't start: ${result.error.message}`;
  }
  if (result.signal) {
    return `stopped by ${result.signal}`;
  }
  return `exited ${result.status}`;
}

// What a wrangler process, or the migration check that loads wrangler, sees.
function wranglerEnv(extra = {}) {
  return {
    ...without(process.env, NEVER),
    CI: "true",
    HOME: join(scratch, "home"),
    USERPROFILE: join(scratch, "home"),
    WRANGLER_HIDE_BANNER: "true",
    WRANGLER_LOG_PATH: join(scratch, "logs"),
    WRANGLER_LOG_SANITIZE: "true",
    WRANGLER_SEND_METRICS: "false",
    XDG_CONFIG_HOME: join(scratch, "config"),
    ...extra,
  };
}

async function wrangler(args, { capture = false } = {}) {
  calls += 1;
  const output = join(scratch, `output-${calls}.ndjson`);
  const result = await spawn(
    process.execPath,
    [wranglerBin, ...args, "--config", config, "--env", settings.env],
    {
      cwd: scratch,
      env: wranglerEnv({ WRANGLER_OUTPUT_FILE_PATH: output }),
      capture,
      captureStderr: true,
      timeout: wranglerTimeout,
    },
  );
  checkInterrupted();
  let records = [];
  if (existsSync(output)) {
    records = readFileSync(output, "utf8")
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line));
  }
  const ok = result.status === 0;
  if (!ok) {
    console.error(
      `worker_deploy: wrangler ${args.slice(0, 2).join(" ")} ${describe(result)}`,
    );
  }
  // Wrangler 4.158.0 renders API errors on stderr as `[code: <number>]`,
  // including nested error notes; its ndjson records describe successes.
  const versionMissing =
    !ok &&
    !result.timedOut &&
    !result.error &&
    !result.signal &&
    /\[code:\s*100146\]/.test(stripVTControlCharacters(result.stderr));
  return { ok, stdout: result.stdout, records, versionMissing };
}

async function liveVersions() {
  const status = await wrangler(["deployments", "status", "--json"], {
    capture: true,
  });
  if (!status.ok) {
    return null;
  }
  let live;
  try {
    live = JSON.parse(status.stdout);
  } catch {
    fail("wrangler deployments status printed something other than JSON");
  }
  if (!Array.isArray(live?.versions)) {
    fail("wrangler deployments status reported no versions");
  }
  return live.versions;
}

// Fails when the config's last Durable Object migration isn't the live
// script's applied tag. A config without migrations is always fine. If the
// tags can't be read for one that has them, the answer is unknown, so the
// deploy stops: shipping code that needs a migration that hasn't run is
// worse than stopping.
async function refusePendingMigration() {
  const resultFile = join(scratch, "migrations.json");
  const result = await spawn(
    process.execPath,
    [join(here, "migrations.mjs"), config, settings.env, resultFile],
    {
      cwd: scratch,
      env: wranglerEnv(
        // A test points the API at a stand-in; outside a test it's ignored.
        process.env.TEST_TMPDIR && process.env.TBHB_DEPLOY_API
          ? { CLOUDFLARE_API_BASE_URL: process.env.TBHB_DEPLOY_API }
          : {},
      ),
      timeout: wranglerTimeout,
    },
  );
  checkInterrupted();
  if (result.status !== 0 || !existsSync(resultFile)) {
    fail(
      `can't read the Durable Object migrations of the ${settings.env} Worker (${describe(result)}), ` +
        "so can't tell whether one is pending; nothing was uploaded",
    );
  }
  const { last, applied } = JSON.parse(readFileSync(resultFile, "utf8"));
  if (last === null || last === applied) {
    return;
  }
  fail(
    `the ${settings.env} Worker has a pending Durable Object migration: ` +
      `${settings.config} ends at tag ${JSON.stringify(last)} but the live script's ` +
      `applied tag is ${applied === null ? "none" : JSON.stringify(applied)}. ` +
      "wrangler versions upload can't apply migrations, so nothing was uploaded. " +
      "Apply it once with a plain deploy, which puts the code you have checked out live at 100%, then rerun this target: " +
      `wrangler deploy --config ${settings.config} --env ${settings.env}`,
  );
}

function same(versions, expected) {
  const key = (vs) =>
    vs
      .map((v) => `${v.version_id}@${v.percentage}`)
      .sort()
      .join(" ");
  return key(versions) === key(expected);
}

async function deployVersions(specs, message) {
  for (let attempt = 0; ; attempt += 1) {
    const result = await wrangler([
      "versions",
      "deploy",
      ...specs,
      "--yes",
      `--message=${message}`,
    ]);
    if (result.ok) {
      return;
    }
    // The restore keeps its own retry policy. Only a missing version gets
    // this backoff; all other failures follow the existing failure path.
    if (restoring || !result.versionMissing || attempt === 3) {
      fail(`wrangler versions deploy ${specs.join(" ")} failed`);
    }
    const delay = RETRY_PAUSE * 2 ** attempt;
    console.error(
      `worker_deploy: wrangler versions deploy failed with code 100146; retrying in ${delay / 1000}s`,
    );
    await pause(delay);
    checkInterrupted();
  }
}

async function runTests(phase, targets, env) {
  const hidden = [...NEVER, ...CREDENTIALS].filter(
    (name) => !settings.pass_env.includes(name),
  );
  const began = Date.now();
  for (const target of targets) {
    console.log(`worker_deploy: ${phase}-deploy test ${target}`);
    for (;;) {
      const result = await spawn(runfile(target), [], {
        env: {
          ...without(process.env, hidden),
          ...env,
          RUNFILES_DIR: runfiles,
        },
        timeout: testTimeout,
      });
      checkInterrupted();
      if (result.status === 0) {
        break;
      }
      if (Date.now() - began >= SETTLE) {
        return `${target} ${describe(result)}`;
      }
      console.error(
        `worker_deploy: ${phase}-deploy test ${target} failed (${describe(result)}); retrying in ${RETRY_PAUSE / 1000}s`,
      );
      await pause(RETRY_PAUSE);
      checkInterrupted();
    }
  }
  return null;
}

function report(name, value) {
  if (process.env.GITHUB_OUTPUT) {
    appendFileSync(process.env.GITHUB_OUTPUT, `${name}=${value}\n`);
  }
}

function summary(line) {
  if (process.env.GITHUB_STEP_SUMMARY) {
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${line}\n`);
  }
}

function sleep(ms) {
  return new Promise((done) => setTimeout(done, ms));
}

// Resolves after ms, or at once when a signal arrives.
function pause(ms) {
  return new Promise((done) => {
    const timer = setTimeout(finish, ms);
    function finish() {
      clearTimeout(timer);
      wake = null;
      done();
    }
    wake = finish;
  });
}

const message = settings.message || "worker_deploy";
let exitCode = 1;
// Set once the new version is part of the deployment: from then on any
// failure, expected or not, puts the previous version back.
let restore = null;
let result = "failure";
try {
  // 1. The live deployment.
  const versions = await liveVersions();
  if (versions === null) {
    fail(
      `can't read the live deployment of the ${settings.env} Worker. ` +
        "A Worker's first deploy is a one-time bootstrap outside this target; " +
        "after it, this target deploys every version.",
    );
  }
  if (versions.length !== 1 || versions[0].percentage !== 100) {
    fail(
      `the ${settings.env} Worker is split across ${versions.length} versions; ` +
        "finish or roll back that deployment first",
    );
  }
  const previous = versions[0].version_id;
  if (!UUID.test(previous ?? "")) {
    fail(`the live version id ${JSON.stringify(previous)} isn't a UUID`);
  }
  report("previous-version-id", previous);
  await refusePendingMigration();

  // 2. Upload.
  const secretsFile = join(scratch, "secrets.json");
  writeFileSync(secretsFile, JSON.stringify(secrets), { mode: 0o600 });
  let upload;
  try {
    upload = await wrangler([
      "versions",
      "upload",
      runfile(settings.script),
      "--no-bundle",
      "--secrets-file",
      secretsFile,
      `--message=${message}`,
    ]);
  } finally {
    rmSync(secretsFile, { force: true });
  }
  const uploaded = upload.records.find((r) => r.type === "version-upload");
  if (!upload.ok || uploaded === undefined) {
    fail("wrangler versions upload failed");
  }
  const version = uploaded.version_id;
  const worker = uploaded.worker_name;
  if (!UUID.test(version ?? "") || !worker) {
    fail("wrangler reported no version id or Worker name for the upload");
  }

  // 3 and 4. The new version at 0%, tested through the override header.
  const split = [
    { version_id: previous, percentage: 100 },
    { version_id: version, percentage: 0 },
  ];
  restore = async () => {
    // Putting the previous version back is safe to repeat; only a version
    // that's neither ours nor the previous one (another deploy) stops it.
    // A status that can't be read doesn't.
    let now = null;
    try {
      now = await liveVersions();
    } catch (error) {
      console.error(`worker_deploy: ${error.message}`);
    }
    const other = now?.find(
      (v) => v.version_id !== previous && v.version_id !== version,
    );
    if (other !== undefined) {
      console.error(
        `worker_deploy: ${other.version_id} is deployed now, by another deploy; leaving the deployment as it is`,
      );
      return;
    }
    console.error(`worker_deploy: putting ${previous} back at 100%`);
    await deployVersions([`${previous}@100%`], `${message} (restored)`);
  };
  await deployVersions(
    [`${previous}@100%`, `${version}@0%`],
    `${message} (0%)`,
  );
  const base = {
    WORKER_ENV: settings.env,
    WORKER_NAME: worker,
    WORKER_URL: settings.url,
    WORKER_VERSION_ID: version,
  };
  const pre = await runTests("pre", settings.pre_deploy, {
    ...base,
    WORKER_REQUEST_HEADERS: JSON.stringify({
      "Cloudflare-Workers-Version-Overrides": `${worker}="${version}"`,
    }),
  });
  if (pre !== null) {
    fail(`pre-deploy test ${pre}; ${version} never took traffic`);
  }

  // 5. Live, if nobody changed the deployment meanwhile. Whether the
  // status lists a 0% version isn't documented, so both forms count.
  const now = await liveVersions();
  if (
    now === null ||
    !(
      same(now, split) || same(now, [{ version_id: previous, percentage: 100 }])
    )
  ) {
    fail(
      "the deployment changed during the pre-deploy tests; another deploy may be running",
    );
  }
  await deployVersions([`${version}@100%`], message);
  const post = await runTests("post", settings.post_deploy, {
    ...base,
    WORKER_REQUEST_HEADERS: "{}",
  });
  if (post !== null) {
    if (!settings.rollback) {
      restore = null;
      fail(`post-deploy test ${post}; ${version} stays live`);
    }
    result = "rolled-back";
    fail(`post-deploy test ${post}`);
  }
  restore = null;
  result = "success";
  report("version-id", version);
  report("url", settings.url);
  const line = `Deployed ${worker} version ${version} to ${settings.env} (${settings.url}), replacing ${previous}.`;
  console.log(`worker_deploy: ${line}`);
  summary(line);
  exitCode = 0;
} catch (error) {
  console.error(
    `worker_deploy: ${error instanceof Failure ? error.message : error.stack}`,
  );
  if (restore !== null) {
    let restored = false;
    // A signal from here on neither stops the restore nor counts against it.
    restoring = true;
    for (let attempt = 1; attempt <= 3 && !restored; attempt += 1) {
      if (attempt > 1) {
        await sleep(2000 * (attempt - 1));
      }
      try {
        await restore();
        restored = true;
      } catch (again) {
        console.error(
          `worker_deploy: restore attempt ${attempt} failed: ${again.message}`,
        );
      }
    }
    if (!restored) {
      result = "restore-failed";
      const command = `wrangler versions deploy <previous-version-id>@100% --env ${settings.env}`;
      console.log(
        `::error::worker_deploy couldn't restore the previous version of the ${settings.env} Worker. Run: ${command}`,
      );
      summary(
        `worker_deploy couldn't restore the previous ${settings.env} version. Run \`${command}\` with the previous-version-id output.`,
      );
    }
  }
  if (process.env.RUNNER_TEMP && existsSync(join(scratch, "logs"))) {
    const kept = join(process.env.RUNNER_TEMP, `wrangler-logs-${process.pid}`);
    cpSync(join(scratch, "logs"), kept, { recursive: true });
    console.error(`worker_deploy: wrangler's logs are in ${kept}`);
  }
} finally {
  rmSync(scratch, { recursive: true, force: true });
  report("result", result);
}
process.exit(exitCode);
