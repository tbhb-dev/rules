# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`repo_layout_test`: the repository's top-level directories and script dirs."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("//shell:defs.bzl", "SHELL_ATTRS", "SHELL_TOOLCHAINS", "shell_executable")

# Internal: consumers load //repo:defs.bzl.
visibility("//repo/...")

_SCRIPT_KINDS = ["pep723"]

def _name(value, what):
    if not value or "/" in value or value in (".", ".."):
        fail("{} must be a single directory name, not {}".format(what, repr(value)))
    return value

def _relative(file, strip_prefix):
    if file.owner.repo_name != "":
        fail("{} is from repository @{}; only files of the main repository can be checked".format(
            file.short_path,
            file.owner.repo_name,
        ))
    if not strip_prefix:
        return file.short_path
    if not file.short_path.startswith(strip_prefix + "/"):
        fail("{} is not under strip_prefix {}".format(file.short_path, strip_prefix))
    return file.short_path[len(strip_prefix) + 1:]

def _repo_layout_test_impl(ctx):
    top = [_name(d, "a top_level_dirs entry") for d in ctx.attr.top_level_dirs]
    if not top:
        fail("top_level_dirs must name at least one directory")
    rules = ["top\t" + d for d in top]
    for dir, kind in ctx.attr.scripts.items():
        _name(dir, "a scripts key")
        if dir not in top:
            fail("scripts names {}, which is not in top_level_dirs".format(dir))
        if kind not in _SCRIPT_KINDS:
            fail("scripts[{}] is {}; the kinds are {}".format(dir, repr(kind), _SCRIPT_KINDS))
        rules.append("script\t{}\t{}".format(dir, kind))
    for dir, names in ctx.attr.allowed_subdirs.items():
        if dir not in ctx.attr.scripts:
            fail("allowed_subdirs names {}, which is not a scripts directory".format(dir))
        rules.extend(["subdir\t{}\t{}".format(dir, _name(n, "an allowed_subdirs entry")) for n in names])

    strip_prefix = ctx.attr.strip_prefix.strip("/")
    files = ctx.files.srcs
    manifest = ctx.actions.declare_file(ctx.label.name + ".manifest")
    ctx.actions.write(
        output = manifest,
        content = "".join(["{}\t{}\n".format(_relative(f, strip_prefix), f.short_path) for f in files]),
    )
    rules_file = ctx.actions.declare_file(ctx.label.name + ".rules")
    ctx.actions.write(output = rules_file, content = "\n".join(rules) + "\n")

    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._runner,
        output = script,
        substitutions = {
            "@@MANIFEST@@": shell.quote(manifest.short_path),
            "@@RULES@@": shell.quote(rules_file.short_path),
        },
        is_executable = True,
    )
    executable, runfiles = shell_executable(
        ctx,
        script,
        ctx.runfiles(files = [manifest, rules_file] + files),
    )
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

repo_layout_test = rule(
    implementation = _repo_layout_test_impl,
    test = True,
    toolchains = SHELL_TOOLCHAINS,
    doc = """Checks the repository's layout, reporting each problem as `path: problem`.

Every top-level directory that holds a file in `srcs` must be named in
`top_level_dirs`, so a new area of the repository arrives as a deliberate
change. Top-level files are not checked.

Every file directly under a `scripts` directory must suit its kind. The one
kind, `pep723`, is an extensionless uv script: its first line is
`#!/usr/bin/env -S uv run --script`, and a later line is `# /// script`,
opening its inline metadata. A script directory holds no subdirectories but
those `allowed_subdirs` names, whose files are not checked.

`srcs` is usually a `repo_files` target, which lists the files Bazel sees:
the REPO.bazel ignores apply, but not .gitignore.""",
    attrs = SHELL_ATTRS | {
        "allowed_subdirs": attr.string_list_dict(doc = "Per scripts directory, the subdirectory names it may hold."),
        "scripts": attr.string_dict(doc = "Top-level directory to script kind; the kind is `pep723`."),
        "srcs": attr.label_list(allow_files = True, mandatory = True, doc = "Files to check, usually a `repo_files` target."),
        "strip_prefix": attr.string(doc = "Repository-relative directory to treat as the root."),
        "top_level_dirs": attr.string_list(mandatory = True, doc = "The top-level directories allowed."),
        "_runner": attr.label(default = ":repo_layout.sh.tpl", allow_single_file = True),
    },
)
