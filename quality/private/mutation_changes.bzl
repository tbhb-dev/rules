# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`mutation_changes`: writes the change set of a diff-scoped mutation run."""

load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "path_dir", "shell_executable")

# Internal: consumers use //quality:mutation_changes.
visibility("//quality/...")

def _mutation_changes_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {"@@GIT_DIR@@": path_dir(ctx.attr.git)},
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable.git])
    runfiles = runfiles.merge(ctx.attr.git[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

mutation_changes = rule(
    implementation = _mutation_changes_impl,
    executable = True,
    toolchains = SHELL_TOOLCHAINS,
    doc = """Writes a change set for `--@tbhb_rules//quality:changes`; run it with `bazel run`.

`-- --base REV --out FILE` diffs the merge base of REV and HEAD against the
working tree. The file is an input of the mutation actions, so it is the
only way the diff reaches them: they stay hermetic and cached by its
content.""",
    attrs = SHELL_ATTRS | {
        "git": attr.label(
            default = "@tbhb_rules_git//:git",
            executable = True,
            cfg = "target",
            allow_files = True,
            doc = "The git put first on PATH.",
        ),
        "_runner": attr.label(
            default = ":mutation_changes.sh.tpl",
            allow_single_file = True,
        ),
    },
)
