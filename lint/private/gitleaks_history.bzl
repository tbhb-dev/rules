# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`gitleaks_history`: scans the workspace's git history for secrets."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")

# Internal: consumers load //lint:defs.bzl.
visibility("//lint/...")

def _gitleaks_history_impl(ctx):
    git = ctx.executable.git
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {
            "@@CONFIG@@": shell.quote(ctx.file.config.short_path if ctx.file.config else ""),
            "@@GIT_DIR@@": git.short_path.rpartition("/")[0],
            "@@TOOL@@": ctx.executable.tool.short_path,
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable.tool, git])
    runfiles = runfiles.merge(ctx.attr.tool[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(ctx.attr.git[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

gitleaks_history = rule(
    implementation = _gitleaks_history_impl,
    executable = True,
    toolchains = SHELL_TOOLCHAINS,
    doc = """Scans the workspace's git history with gitleaks; run it with `bazel run`.

Fails on any finding, when the repository has no commits, and when gitleaks
scans no commits although the history holds content (gitleaks exits 0 when
its own git invocation fails). A shallow clone scans only the commits it
has, so CI should fetch the full history. The working tree is
`gitleaks_test`'s job.""",
    attrs = SHELL_ATTRS | {
        "config": attr.label(
            allow_single_file = True,
            doc = "gitleaks config, a file of the main repository.",
        ),
        "git": attr.label(
            default = "@tbhb_rules_git//:git",
            executable = True,
            cfg = "target",
            allow_files = True,
            doc = "The git put first on PATH for gitleaks.",
        ),
        "tool": attr.label(
            default = "@tbhb_rules_gitleaks//:gitleaks",
            executable = True,
            cfg = "target",
            allow_files = True,
            doc = "The gitleaks executable.",
        ),
        "_runner": attr.label(
            default = ":gitleaks_history.sh.tpl",
            allow_single_file = True,
        ),
    },
)
