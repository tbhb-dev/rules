// SPDX-License-Identifier: Apache-2.0
// Copyright Tony Burns

// worker_deploy's migration check (deploy.mjs runs it as a child): reads the
// Durable Object migrations the wrangler config declares for an environment,
// and when there are any, the migration tag the live script has applied.
//
//   node migrations.mjs <config> <env> <result file>
//
// The result file gets { name, last, applied } as JSON: the Worker's name,
// the tag of the config's last migration (null when it has none), and the
// live script's applied tag (null when it has applied none; undefined when
// the config has no migrations, since the API isn't asked). Any failure
// exits non-zero with the reason on stderr and no result.
//
// The config comes from wrangler's own reader, so an environment's name,
// inherited fields and file format resolve as they do for `wrangler versions
// upload`. The live tag comes from the same service-metadata endpoint
// wrangler's own pending-migration check reads.
import { writeFileSync } from "node:fs";
import { unstable_readConfig as readConfig } from "wrangler";

const [config, env, resultFile] = process.argv.slice(2);

const { name, migrations } = readConfig(
  { config, env },
  { hideWarnings: true },
);
const result = { name, last: migrations.at(-1)?.tag ?? null };

if (result.last !== null) {
  const base =
    process.env.CLOUDFLARE_API_BASE_URL ??
    "https://api.cloudflare.com/client/v4";
  const url = `${base}/accounts/${process.env.CLOUDFLARE_ACCOUNT_ID}/workers/services/${encodeURIComponent(name)}`;
  const response = await fetch(url, {
    headers: { Authorization: `Bearer ${process.env.CLOUDFLARE_API_TOKEN}` },
  });
  const body = await response.json().catch(() => null);
  if (!response.ok || body?.success !== true) {
    const errors = (body?.errors ?? [])
      .map((e) => `${e.code}: ${e.message}`)
      .join("; ");
    console.error(
      `migrations: GET ${new URL(url).pathname} answered ${response.status}${errors ? ` (${errors})` : response.ok ? " without success" : ""}`,
    );
    process.exit(1);
  }
  const script = body.result?.default_environment?.script;
  if (script === undefined) {
    console.error(
      `migrations: GET ${new URL(url).pathname} reported no script`,
    );
    process.exit(1);
  }
  result.applied = script.migration_tag ?? null;
}

writeFileSync(resultFile, JSON.stringify(result));
