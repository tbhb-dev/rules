# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`commit_messages`: checks the subject of each commit in a range."""

load("//runtime:defs.bzl", "python_tool")
load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "path_dir", "shell_executable")

# Internal: consumers run //lint:commit_messages.
visibility("//lint/...")

def _commit_messages_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {
            "@@GIT_DIR@@": path_dir(ctx.attr.git),
            "@@SUBJECTS@@": ctx.executable.subjects.short_path,
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable.git, ctx.executable.subjects])
    runfiles = runfiles.merge(ctx.attr.git[DefaultInfo].default_runfiles)
    runfiles = runfiles.merge(ctx.attr.subjects[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

_commit_messages = rule(
    implementation = _commit_messages_impl,
    executable = True,
    toolchains = SHELL_TOOLCHAINS,
    doc = """Checks the subject of each non-merge commit in `BASE..HEAD`; run it with `bazel run <target> -- BASE HEAD`.

Fails on a subject that is not `type(scope): summary`, is over 72 characters,
starts with `fixup!`, `squash!` or `amend!`, carries a WIP marker, or is a bare
generic word such as `fix` or `address review`.""",
    attrs = SHELL_ATTRS | {
        "git": attr.label(
            default = "@tbhb_rules_git//:git",
            executable = True,
            cfg = "target",
            allow_files = True,
            doc = "The git that reads the history.",
        ),
        "subjects": attr.label(executable = True, cfg = "target", mandatory = True),
        "_runner": attr.label(
            default = ":commit_messages.sh.tpl",
            allow_single_file = True,
        ),
    },
)

def commit_messages(name, **kwargs):
    """Check each non-merge commit subject in a range.

    Args:
        name: Target name.
        **kwargs: Passed to the executable range check.
    """
    python_tool(
        name = name + ".subjects",
        main = Label(":commit_messages/check_subject.py"),
        python_env = Label("@tbhb_rules_python_runtime//:env"),
        tags = ["manual"],
        visibility = ["//visibility:private"],
    )
    _commit_messages(name = name, subjects = ":" + name + ".subjects", **kwargs)
