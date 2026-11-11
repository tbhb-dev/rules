# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`commit_identity`: checks who authored and committed each commit in a range."""

load("//runtime:defs.bzl", "python_tool")
load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "path_dir", "shell_executable")

# Internal: consumers run //lint:commit_identity.
visibility("//lint/...")

# The (author, committer) pairs a pull request's commits may carry, as
# `Name <email> -> Name <email>`. Every repository that runs
# repo-checks.yml checks against this one list.
ALLOWED_PAIRS = [
    "tbhb.dev Agent <agent@tonyburns.net> -> tbhb.dev Agent <agent@tonyburns.net>",
    "Tony Burns <tony@tonyburns.net> -> Tony Burns <tony@tonyburns.net>",
    # Renovate commits through the API, so GitHub signs and commits them.
    "tbhb-dev-renovate[bot] <289255489+tbhb-dev-renovate[bot]@users.noreply.github.com> -> GitHub <noreply@github.com>",
]

def _commit_identity_impl(ctx):
    allowed = ctx.actions.declare_file(ctx.label.name + ".allowed")
    ctx.actions.write(output = allowed, content = "\n".join(ALLOWED_PAIRS) + "\n")
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {
            "@@ALLOWED@@": allowed.short_path,
            "@@GIT_DIR@@": path_dir(ctx.attr.git),
            "@@TRAILERS@@": ctx.executable.trailers.short_path,
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [allowed, ctx.executable.git, ctx.executable.trailers])
    runfiles = runfiles.merge(ctx.attr.git[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(ctx.attr.trailers[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

_commit_identity = rule(
    implementation = _commit_identity_impl,
    executable = True,
    toolchains = SHELL_TOOLCHAINS,
    doc = """Checks each commit in `BASE..HEAD` against `ALLOWED_PAIRS`; run it with `bazel run <target> -- BASE HEAD`.

Fails on any commit whose author and committer, together, are not one of
the allowed pairs, and names the commit and both identities. Agent authors or
committers also require valid identity trailers without sign-off or co-author lines.""",
    attrs = SHELL_ATTRS | {
        "git": attr.label(
            default = "@tbhb_rules_git//:git",
            executable = True,
            cfg = "target",
            allow_files = True,
            doc = "The git that reads the history.",
        ),
        "trailers": attr.label(executable = True, cfg = "target", mandatory = True),
        "_runner": attr.label(
            default = ":commit_identity.sh.tpl",
            allow_single_file = True,
        ),
    },
)

def commit_identity(name, **kwargs):
    """Check allowed identity pairs and require valid trailers on agent commits.

    Args:
        name: Target name.
        **kwargs: Passed to the executable range check.
    """
    python_tool(
        name = name + ".trailers",
        main = Label(":commit_identity/check_trailers.py"),
        python_env = Label("@tbhb_rules_python_runtime//:env"),
        tags = ["manual"],
        visibility = ["//visibility:private"],
    )
    _commit_identity(name = name, trailers = ":" + name + ".trailers", **kwargs)
