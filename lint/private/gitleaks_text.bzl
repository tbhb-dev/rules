# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`gitleaks_text`: scans the text on stdin for secrets."""

load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")

# Internal: //lint:gitleaks_text is the one target.
visibility("//lint/...")

def _gitleaks_text_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {"@@TOOL@@": ctx.executable.tool.short_path},
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [ctx.executable.tool])
    runfiles = runfiles.merge(ctx.attr.tool[DefaultInfo].default_runfiles)
    executable, runfiles = shell_executable(ctx, script, runfiles)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

gitleaks_text = rule(
    implementation = _gitleaks_text_impl,
    executable = True,
    toolchains = SHELL_TOOLCHAINS,
    doc = """Scans the text on stdin with `gitleaks stdin`; run it with `bazel run`.

It runs in the workspace root and names `.gitleaks.toml` as the config when
the root has one, so under `--//lint:gitleaks_private_config` the private
config from `GITLEAKS_CONFIG_TOML` applies, as for `gitleaks_test`. It fails
on any finding. Arguments go to `gitleaks stdin`.""",
    attrs = SHELL_ATTRS | {
        "tool": attr.label(
            default = Label("//lint/private:gitleaks"),
            executable = True,
            cfg = "target",
            allow_files = True,
            doc = "The gitleaks executable; see `gitleaks_tool`.",
        ),
        "_runner": attr.label(
            default = ":gitleaks_text.sh.tpl",
            allow_single_file = True,
        ),
    },
)
