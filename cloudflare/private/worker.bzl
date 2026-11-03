# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Rules that build and check a Worker with the pinned wrangler."""

load("@aspect_rules_js//js:defs.bzl", "js_binary", "js_run_binary")
load("@tbhb_rules//lint:defs.bzl", "tree_check_test")

# Internal: consumers load //:defs.bzl.
visibility("//...")

# wrangler never phones home or prompts from Bazel, and keeps its home,
# config and logs in .wrangler/ under its working directory: the sandbox
# can't write the user's (~/Library/Preferences/.wrangler on macOS, or a
# legacy ~/.wrangler, which wrangler prefers to XDG_CONFIG_HOME), and a
# developer's own `wrangler login` must never reach a build. The banner
# would check the npm registry for a newer wrangler.
_ENV = {
    "CI": "true",
    "HOME": ".wrangler/home",
    "USERPROFILE": ".wrangler/home",
    "WRANGLER_HIDE_BANNER": "true",
    "WRANGLER_LOG_PATH": ".wrangler/logs",
    "WRANGLER_SEND_METRICS": "false",
    "XDG_CONFIG_HOME": ".wrangler/config",
}

def worker_bundle(name, srcs, config = "wrangler.jsonc", env = None, node_modules = None, **kwargs):
    """Bundles a Worker the way `wrangler deploy` would, without deploying it.

    Runs `wrangler deploy --dry-run --outdir`, so the output directory holds
    exactly the script a deploy uploads (`index.js` and its source map). A
    config error, such as a binding wrangler can't resolve, fails the build.
    The README wrangler writes beside them carries a timestamp, so it's
    removed to keep the output reproducible.

    Args:
        name: Target name, and the output directory.
        srcs: The Worker's sources and config, and its `tsconfig.json`.
        config: The wrangler config, relative to the package.
        env: The wrangler environment to bundle for, or None for the top level.
        node_modules: The consumer's `npm_link_all_packages` target, when the
            Worker imports packages.
        **kwargs: Passed to `js_run_binary`.
    """
    args = ["deploy", "--dry-run", "--outdir", name, "--config", config]
    if env:
        args += ["--env", env]
    js_run_binary(
        name = name,
        tool = Label("//:bundle"),
        srcs = srcs + ([node_modules] if node_modules else []),
        args = args,
        chdir = native.package_name(),
        env = _ENV,
        out_dirs = [name],
        silent_on_success = True,
        **kwargs
    )

def worker_types_test(name, srcs, config = "wrangler.jsonc", types = "worker-configuration.d.ts", **kwargs):
    """Checks that a Worker's committed types are exactly what `wrangler types` writes.

    `wrangler types` writes the `Env` interface from the config's bindings
    and the runtime types for the config's compatibility date and flags, from
    the pinned wrangler's workerd. The check regenerates the file in its copy
    of the tree and compares all of it; `wrangler types --check` would read
    only the header. `bazel run <name>.update` rewrites the committed file.

    The file runs to about 16,000 lines, nearly all runtime types, and every
    wrangler bump that moves workerd rewrites much of it. A wrangler update
    (from Renovate, say) therefore fails this check until someone runs the
    `.update` target on that branch and commits the result; that red check is
    expected, not a regression.

    Commit the file, mark it generated, and keep it out of the other gates:
    `worker-configuration.d.ts linguist-generated=true` in `.gitattributes`,
    and exclude it from cspell, Vale, Biome (`files.includes`), ESLint
    (`ignores`), knip, dependency-cruiser, editorconfig-checker and any
    pre-commit hook that trims whitespace (wrangler writes tabs and trailing
    spaces). tsc_test needs it in `srcs` and the tsconfig's `include`.

    The check's tree is rooted at this package, so a Worker in a
    subdirectory of the repository works like one at its root.

    The `.update` target leaves wrangler's project cache (`.wrangler/`)
    beside the config; gitignore it, as for any wrangler project.

    Args:
        name: Target name.
        srcs: The wrangler config, the types file, the Worker's main
            script (the types name it), and any `.dev.vars`.
        config: The wrangler config, relative to the package.
        types: The committed types file, relative to the package.
        **kwargs: Passed to `tree_check_test`.
    """
    update = "//{}:{}.update".format(native.package_name(), name)
    if native.package_name() and "strip_prefix" not in kwargs:
        kwargs["strip_prefix"] = native.package_name()
    env = dict(_ENV)

    # The js_binary launcher refuses to start outside its own `bazel run`
    # or test unless BAZEL_BINDIR is set; "." is its documented value for a
    # program that is not a build action.
    env["BAZEL_BINDIR"] = "."
    tree_check_test(
        name = name,
        srcs = srcs,
        tool = Label("//:check_types"),
        tool_args = [config, types, update],
        env = env,
        output_guard = "check_types: .* matches",
        **kwargs
    )
    js_binary(
        name = name + ".update",
        data = [Label("//:node_modules/wrangler")],
        entry_point = Label("//:run"),
        args = ["types", "--config", config, types],
        env = dict(_ENV, TBHB_PACKAGE = native.package_name()),
        tags = ["manual"],
    )

def worker_deploy(
        name,
        srcs,
        env,
        url,
        config = "wrangler.jsonc",
        node_modules = None,
        secrets = {},
        pre_deploy = [],
        post_deploy = [],
        pass_env = [],
        rollback = True,
        message = "",
        test_timeout = 300,
        wrangler_timeout = 600,
        **kwargs):
    """A `bazel run` target that deploys a Worker, tested before and after it takes traffic.

    The target bundles the Worker for `env` (a `worker_bundle` named
    `<name>.bundle`) and reads the live deployment, which must be one version
    at 100%; a Worker's first deploy is a one-time bootstrap outside it. It
    uploads the bundle as a new version with the Worker's `secrets`, deploys
    it at 0% beside the live version, and runs each `pre_deploy` target
    against it through the `Cloudflare-Workers-Version-Overrides` header.
    Only when they pass, and the deployment is still the one it made, does it
    move the new version to 100% and run each `post_deploy` target against
    `url`. A failing test is retried for up to 60 seconds (a deployment takes
    effect a few seconds after the API returns), with `test_timeout` per
    attempt. A pre-deploy test that still fails leaves the previous version
    serving everything; a post-deploy test that still fails puts it back at
    100% unless `rollback` is False. Either way the target exits non-zero,
    so a workflow stops before the next environment. SIGINT and SIGTERM
    (Ctrl-C, a cancelled workflow) stop the running wrangler call or test,
    restore the previous version and clean up; SIGKILL can't. A test or
    wrangler call that outlives its timeout is stopped with its whole
    process tree.

    Each test target is an executable that gets `WORKER_URL`, `WORKER_ENV`,
    `WORKER_NAME`, `WORKER_VERSION_ID` and `WORKER_REQUEST_HEADERS` (a JSON
    object of headers to send: the version override before the move, empty
    after), plus this process's environment without the Cloudflare
    credentials and the secrets' variables, except those `pass_env` names.

    Credentials come from `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`;
    a global API key (`CLOUDFLARE_API_KEY`, `CLOUDFLARE_EMAIL` or their `CF_`
    names) is never passed to wrangler. Secrets are uploaded with the version
    from a file in a private scratch directory (under `RUNNER_TEMP` in
    GitHub Actions) that's removed right after; on Windows, which has no
    file modes, only the directory's inherited permissions protect it; secrets not named are kept,
    since deploys never delete them. The target writes `result`,
    `previous-version-id`, and on success `version-id` and `url` to
    `$GITHUB_OUTPUT`, a line to the step summary, and keeps wrangler's logs
    in `RUNNER_TEMP` after a failure.

    Two deploys of one Worker must never overlap: give the workflow job a
    `concurrency` group per Worker and environment. The target refuses to
    move traffic if the deployment changed during its pre-deploy tests.

    Args:
        name: Target name.
        srcs: The Worker's sources and config, as for `worker_bundle`.
        env: The wrangler environment to deploy.
        url: The Worker's URL in that environment, for the tests.
        config: The wrangler config file, in this package (rules_js copies
            a js_binary's source data only from its own package).
        node_modules: The consumer's `npm_link_all_packages` target, when the
            Worker imports packages.
        secrets: Worker secret name to the environment variable holding its value.
        pre_deploy: Executables to run against the new version at 0%.
        post_deploy: Executables to run against the live URL after the move.
        pass_env: Variables the tests may see although they hold credentials
            or secret values, such as a token the tests send.
        rollback: Put the previous version back when a post-deploy test fails.
        message: The deployment message; defaults to "worker_deploy".
        test_timeout: Seconds each attempt of a test may run before it
            counts as failed.
        wrangler_timeout: Seconds each wrangler call may run.
        **kwargs: Passed to `js_binary`.
    """
    bundle = name + ".bundle"
    worker_bundle(
        name = bundle,
        srcs = srcs,
        config = config,
        env = env,
        node_modules = node_modules,
        tags = kwargs.get("tags", []),
        testonly = kwargs.get("testonly", False),
    )
    settings = {
        "config": "$(rootpath {})".format(config),
        "env": env,
        "message": message,
        "pass_env": pass_env,
        "post_deploy": ["$(rootpath {})".format(t) for t in post_deploy],
        "pre_deploy": ["$(rootpath {})".format(t) for t in pre_deploy],
        "rollback": rollback,
        "script": "$(rootpath :{})/index.js".format(bundle),
        "secrets": secrets,
        "test_timeout": test_timeout,
        "url": url,
        "wrangler_timeout": wrangler_timeout,
    }
    js_binary(
        name = name,
        data = [
            Label("//:node_modules/wrangler"),
            ":" + bundle,
            config,
        ] + {t: None for t in pre_deploy + post_deploy}.keys(),
        entry_point = Label("//:deploy"),
        env = {"TBHB_DEPLOY": json.encode(settings)},
        **kwargs
    )
