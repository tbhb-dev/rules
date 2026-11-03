// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// Runs the smoke's worker_deploy targets against fake_wrangler.mjs and
// fake_check.mjs, and checks the calls, outputs and cleanup in each case.
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { test } from "node:test";

const runfiles = process.env.RUNFILES_DIR ?? process.env.JS_BINARY__RUNFILES;
const main = join(runfiles, process.env.TEST_WORKSPACE ?? "_main");
const tmp = process.env.TEST_TMPDIR;
const runnerTemp = join(tmp, "runner");
const files = {
  log: join(tmp, "calls.ndjson"),
  state: join(tmp, "state.json"),
  started: join(tmp, "started"),
  attempts: join(tmp, "attempts"),
  output: join(tmp, "github-output"),
  summary: join(tmp, "github-summary"),
};
const OLD = "00000000-0000-4000-8000-000000000001";
const NEW = "00000000-0000-4000-8000-000000000002";
const READ = "read-7f3a9c2e5d";
const MAIN = "main-4b81d0f6a3";

function setup(env, live) {
  for (const file of Object.values(files)) {
    rmSync(file, { force: true });
  }
  rmSync(runnerTemp, { recursive: true, force: true });
  mkdirSync(runnerTemp);
  if (live !== null) {
    writeFileSync(files.state, JSON.stringify(live));
  }
  return {
    ...process.env,
    BAZEL_BINDIR: ".",
    RUNFILES_DIR: runfiles,
    RUNNER_TEMP: runnerTemp,
    CLOUDFLARE_API_TOKEN: "token",
    CLOUDFLARE_ACCOUNT_ID: "account",
    CLOUDFLARE_API_KEY: "global-key",
    CLOUDFLARE_EMAIL: "someone@example.com",
    CF_API_KEY: "old-global-key",
    CF_API_TOKEN: "old-token",
    WRANGLER_LOG: "debug",
    SMOKE_READ_TOKENS: READ,
    SMOKE_MAIN_TOKEN: MAIN,
    FAKE_LOG: files.log,
    FAKE_STATE: files.state,
    FAKE_STARTED: files.started,
    FAKE_ATTEMPTS: files.attempts,
    // Shrinks deploy.mjs's 60 s settle window to 3 s, and its pause to 0.25 s.
    TBHB_DEPLOY_SETTLE_SCALE: "0.05",
    FAKE_NEW: NEW,
    GITHUB_OUTPUT: files.output,
    GITHUB_STEP_SUMMARY: files.summary,
    TBHB_DEPLOY_WRANGLER: join(main, process.env.fake_wrangler),
    ...env,
  };
}

function read(file) {
  return existsSync(file) ? readFileSync(file, "utf8") : "";
}

function outcome(status, stdout, stderr) {
  const calls = read(files.log)
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l));
  const steps = calls.map((c) =>
    c.command === "versions deploy"
      ? `deploy ${c.args.slice(2, c.args.indexOf("--yes")).join(" ")}`
      : c.command,
  );
  const output = read(files.output);
  const summary = read(files.summary);
  // No secret value ever leaves the secrets file.
  for (const text of [stdout, stderr, output, summary]) {
    assert.ok(!text.includes(READ) && !text.includes(MAIN), text);
  }
  // Nothing is left in the scratch area.
  assert.deepEqual(
    readdirSync(runnerTemp).filter((f) => f.startsWith("worker-deploy-")),
    [],
  );
  return { status, stdout, stderr, calls, steps, output, summary };
}

// The launcher is a .bat file on Windows, which Node starts only through
// cmd.exe.
function launcher(target) {
  const file = join(main, process.env[target]);
  if (process.platform === "win32") {
    return [
      process.env.ComSpec ?? "cmd.exe",
      ["/d", "/s", "/c", `""${file}""`],
      { windowsVerbatimArguments: true },
    ];
  }
  return [file, [], {}];
}

function deploy(
  target,
  env = {},
  live = [{ version_id: OLD, percentage: 100 }],
) {
  const [file, args, options] = launcher(target);
  const r = spawnSync(file, args, {
    ...options,
    encoding: "utf8",
    env: setup(env, live),
  });
  return outcome(r.status, r.stdout, r.stderr);
}

// The steps with each run of a repeated step (a test retried) as one.
function once(steps) {
  return steps.filter((step, i) => step !== steps[i - 1]);
}

// Starts a deploy, sends `signal` once the fake reports it has started (or
// `ready` accepts the stderr so far), and waits for the deploy to finish.
async function interrupt(
  signal,
  env,
  ready = () => existsSync(files.started),
) {
  const child = spawn(join(main, process.env.deploy_stg), [], {
    env: setup(env, [{ version_id: OLD, percentage: 100 }]),
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (d) => {
    stdout += d;
  });
  child.stderr.on("data", (d) => {
    stderr += d;
  });
  const closed = new Promise((r) => child.on("close", r));
  let exited = false;
  closed.then(() => {
    exited = true;
  });
  while (!exited && !ready(stderr)) {
    await new Promise((r) => setTimeout(r, 50));
  }
  // The fakes sleep for a minute, so a deploy that finishes this soon
  // stopped them.
  const sent = Date.now();
  child.kill(signal);
  const status = await closed;
  assert.ok(Date.now() - sent < 20_000, "the signal didn't stop the child");
  return outcome(status, stdout, stderr);
}

test("deploys at 0%, tests, moves to 100%, tests again", () => {
  const r = deploy("deploy_stg");
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(r.steps, [
    "deployments status",
    "versions upload",
    `deploy ${OLD}@100% ${NEW}@0%`,
    "check pre",
    "deployments status",
    `deploy ${NEW}@100%`,
    "check post",
  ]);
  const upload = r.calls[1];
  assert.deepEqual(upload.secrets, { READ_TOKENS: READ, MAIN_TOKEN: MAIN });
  // Windows has no file modes.
  if (process.platform !== "win32") {
    assert.equal(upload.secretsMode, "600");
  }
  assert.ok(!existsSync(upload.secretsFile));
  assert.ok(upload.args.includes("--no-bundle"));
  assert.match(upload.args[2], /deploy_stg\.bundle[/\\]index\.js$/);
  for (const call of r.calls.filter((c) => c.args)) {
    const scratch = call.cwd;
    assert.ok(scratch.startsWith(runnerTemp), scratch);
    assert.deepEqual(call.args.slice(-2), ["--env", "stg"]);
    assert.ok(call.env.HOME.startsWith(scratch));
    assert.ok(call.env.USERPROFILE.startsWith(scratch));
    assert.ok(call.env.XDG_CONFIG_HOME.startsWith(scratch));
    assert.ok(call.env.WRANGLER_LOG_PATH.startsWith(scratch));
    assert.equal(call.env.WRANGLER_LOG_SANITIZE, "true");
    assert.equal(call.env.WRANGLER_HIDE_BANNER, "true");
    assert.equal(call.env.CLOUDFLARE_API_TOKEN, "token");
    for (const name of [
      "WRANGLER_LOG",
      "CLOUDFLARE_API_KEY",
      "CLOUDFLARE_EMAIL",
      "CF_API_KEY",
      "CF_API_TOKEN",
    ]) {
      assert.equal(call.env[name], null, name);
    }
  }
  const pre = r.calls[3];
  assert.deepEqual(pre.headers, {
    "Cloudflare-Workers-Version-Overrides": `smoke-stg="${NEW}"`,
  });
  assert.equal(pre.url, "https://smoke-stg.example");
  assert.equal(pre.env, "stg");
  assert.equal(pre.name, "smoke-stg");
  assert.equal(pre.version, NEW);
  // Credentials and secret values reach the tests only through pass_env.
  assert.deepEqual(pre.seen, {
    CLOUDFLARE_API_TOKEN: false,
    CLOUDFLARE_ACCOUNT_ID: false,
    SMOKE_MAIN_TOKEN: false,
    SMOKE_READ_TOKENS: true,
  });
  assert.deepEqual(r.calls[6].headers, {});
  assert.equal(
    r.output,
    `previous-version-id=${OLD}\nversion-id=${NEW}\nurl=https://smoke-stg.example\nresult=success\n`,
  );
  assert.match(
    r.summary,
    new RegExp(`Deployed smoke-stg version ${NEW} to stg`),
  );
});

test("a failed pre-deploy test leaves the previous version serving", () => {
  const r = deploy("deploy_stg", { FAKE_FAIL: "pre" });
  assert.equal(r.status, 1);
  // It was retried until the settle window passed.
  assert.ok(r.steps.filter((s) => s === "check pre").length > 1);
  assert.match(
    r.stderr,
    /pre-deploy test \S+ failed \(exited 1\); retrying in 0\.25s/,
  );
  assert.deepEqual(once(r.steps).slice(2), [
    `deploy ${OLD}@100% ${NEW}@0%`,
    "check pre",
    "deployments status",
    `deploy ${OLD}@100%`,
  ]);
  assert.match(r.stderr, new RegExp(`exited 1; ${NEW} never took traffic`));
  assert.match(r.output, /result=failure\n$/);
  assert.doesNotMatch(r.output, /^version-id=/m);
});

test("a test that fails at first and then passes deploys", () => {
  for (const phase of ["pre", "post"]) {
    const r = deploy("deploy_stg", {
      FAKE_FLAKY: `${phase}:2`,
      TBHB_DEPLOY_SETTLE_SCALE: "0.2",
    });
    assert.equal(r.status, 0, `${phase}: ${r.stderr}`);
    assert.equal(r.steps.filter((s) => s === `check ${phase}`).length, 3);
    assert.equal(
      r.stderr.match(new RegExp(`${phase}-deploy test \\S+ failed`, "g")).length,
      2,
    );
    assert.deepEqual(once(r.steps), [
      "deployments status",
      "versions upload",
      `deploy ${OLD}@100% ${NEW}@0%`,
      "check pre",
      "deployments status",
      `deploy ${NEW}@100%`,
      "check post",
    ]);
    assert.match(r.output, /result=success\n$/);
  }
});

test("a failed post-deploy test rolls back", () => {
  const r = deploy("deploy_stg", { FAKE_FAIL: "post" });
  assert.equal(r.status, 1);
  assert.ok(r.steps.filter((s) => s === "check post").length > 1);
  assert.deepEqual(once(r.steps).slice(-4), [
    `deploy ${NEW}@100%`,
    "check post",
    "deployments status",
    `deploy ${OLD}@100%`,
  ]);
  assert.match(r.stderr, new RegExp(`putting ${OLD} back at 100%`));
  assert.match(r.output, /result=rolled-back\n$/);
});

test("without rollback, a failed post-deploy test leaves the new version live", () => {
  const r = deploy("deploy_stg_no_rollback", { FAKE_FAIL: "post" });
  assert.equal(r.status, 1);
  assert.deepEqual(once(r.steps).slice(-2), [
    `deploy ${NEW}@100%`,
    "check post",
  ]);
  assert.match(r.stderr, /stays live/);
});

test("a restore that keeps failing is reported for a person to finish", () => {
  const r = deploy("deploy_stg", {
    FAKE_FAIL: "post",
    FAKE_DEPLOY_FAIL: `${OLD}@100%`,
  });
  assert.equal(r.status, 1);
  assert.equal(r.steps.filter((s) => s === `deploy ${OLD}@100%`).length, 3);
  assert.match(
    r.stdout,
    /::error::worker_deploy couldn't restore the previous version of the stg Worker/,
  );
  assert.match(r.summary, /couldn't restore the previous stg version/);
  assert.match(r.output, /result=restore-failed\n$/);
});

test("a failed upload deploys nothing", () => {
  for (const upload of ["fail", "silent"]) {
    const r = deploy("deploy_stg", { FAKE_UPLOAD: upload });
    assert.equal(r.status, 1, upload);
    assert.deepEqual(r.steps, ["deployments status", "versions upload"]);
    assert.match(r.stderr, /wrangler versions upload failed/);
  }
});

test("a failed 0% step puts the previous version back, which is safe to repeat", () => {
  const r = deploy("deploy_stg", {
    FAKE_DEPLOY_FAIL: `${OLD}@100% ${NEW}@0%`,
  });
  assert.equal(r.status, 1);
  assert.deepEqual(r.steps.slice(2), [
    `deploy ${OLD}@100% ${NEW}@0%`,
    "deployments status",
    `deploy ${OLD}@100%`,
  ]);
});

test("a failed move to 100% puts the previous version back", () => {
  const r = deploy("deploy_stg", { FAKE_DEPLOY_FAIL: `${NEW}@100%` });
  assert.equal(r.status, 1);
  assert.deepEqual(r.steps.slice(-3), [
    `deploy ${NEW}@100%`,
    "deployments status",
    `deploy ${OLD}@100%`,
  ]);
});

test("refuses to move traffic when another deploy changed the deployment", () => {
  const r = deploy("deploy_stg", { FAKE_INTERFERE: "pre" });
  assert.equal(r.status, 1);
  assert.ok(!r.steps.includes(`deploy ${NEW}@100%`));
  assert.match(r.stderr, /the deployment changed during the pre-deploy tests/);
  assert.match(r.stderr, /someone-else is deployed now, by another deploy/);
  assert.equal(r.steps.at(-1), "deployments status");
});

test("refuses a deployment split across versions", () => {
  const r = deploy("deploy_stg", {}, [
    { version_id: OLD, percentage: 90 },
    { version_id: NEW, percentage: 10 },
  ]);
  assert.equal(r.status, 1);
  assert.deepEqual(r.steps, ["deployments status"]);
  assert.match(r.stderr, /split across 2 versions/);
});

test("points a Worker without deployments at the bootstrap", () => {
  const r = deploy("deploy_stg", {}, null);
  assert.equal(r.status, 1);
  assert.deepEqual(r.steps, ["deployments status"]);
  assert.match(r.stderr, /first deploy is a one-time bootstrap/);
});

test("stops before wrangler when a secret's variable is unset", () => {
  const r = deploy("deploy_stg", { SMOKE_MAIN_TOKEN: "" });
  assert.equal(r.status, 1);
  assert.deepEqual(r.steps, []);
  assert.match(
    r.stderr,
    /SMOKE_MAIN_TOKEN, the value of the Worker secret MAIN_TOKEN, is unset/,
  );
});

test("stops before wrangler without credentials", () => {
  for (const name of ["CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID"]) {
    const r = deploy("deploy_stg", { [name]: "" });
    assert.equal(r.status, 1);
    assert.deepEqual(r.steps, []);
    assert.match(r.stderr, new RegExp(`${name} is unset`));
  }
});

// Windows has no SIGTERM to send a process.
const signals = { skip: process.platform === "win32" };

test(
  "SIGTERM during the upload deploys nothing and cleans up",
  signals,
  async () => {
    const r = await interrupt("SIGTERM", { FAKE_UPLOAD_SLEEP: "60000" });
    assert.notEqual(r.status, 0);
    assert.deepEqual(r.steps, ["deployments status", "versions upload"]);
    assert.ok(!existsSync(r.calls[1].secretsFile));
    assert.match(r.stderr, /interrupted by SIGTERM/);
  },
);

test(
  "SIGTERM during a pre-deploy test puts the previous version back",
  signals,
  async () => {
    const r = await interrupt("SIGTERM", { FAKE_SLEEP: "pre" });
    assert.notEqual(r.status, 0);
    assert.deepEqual(r.steps.slice(-3), [
      "check pre",
      "deployments status",
      `deploy ${OLD}@100%`,
    ]);
    assert.match(r.stderr, /interrupted by SIGTERM/);
  },
);

test(
  "SIGTERM while a failed test waits to be retried puts the previous version back",
  signals,
  async () => {
    // A 60 s pause, so a deploy that ends sooner was woken.
    const r = await interrupt(
      "SIGTERM",
      { FAKE_FAIL: "pre", TBHB_DEPLOY_SETTLE_SCALE: "12" },
      (stderr) => stderr.includes("retrying in 60s"),
    );
    assert.notEqual(r.status, 0);
    assert.deepEqual(r.steps.slice(-3), [
      "check pre",
      "deployments status",
      `deploy ${OLD}@100%`,
    ]);
    assert.equal(r.steps.filter((s) => s === "check pre").length, 1);
    assert.match(r.stderr, /interrupted by SIGTERM/);
  },
);

test(
  "a test that outlives its timeout and ignores SIGTERM is killed",
  signals,
  () => {
    const started = Date.now();
    const r = deploy("deploy_stg_timeout", { FAKE_STUBBORN: "pre" });
    assert.ok(Date.now() - started < 40_000);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /pre-deploy test .* timed out/);
    assert.deepEqual(r.steps.slice(-2), [
      "deployments status",
      `deploy ${OLD}@100%`,
    ]);
  },
);
