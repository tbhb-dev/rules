# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""PyEnvInfo and the rules a generated environment repository calls."""

# Internal: load //runtime:defs.bzl.
visibility("//runtime/...")

PyEnvInfo = provider(
    doc = "A locked Python environment built by the `python` module extension.",
    fields = {
        "bin_dir": "short_path of the environment's bin directory (native tools such as ruff).",
        "files": "depset of every file of the interpreter and the environment.",
        "interpreter": "The interpreter File.",
        "site_packages": "short_path of the site-packages directory.",
        "source_roots": "Source roots of the editable workspace members, relative to the workspace root.",
        "uv": "The uv File.",
    },
)

def _dir_of(files, directory):
    # A path inside the repository becomes a short_path, which is how
    # runfiles name it.
    if not files:
        fail("the environment has no files under {}".format(directory))
    sample = files[0].short_path
    marker = "/" + directory + "/"
    index = sample.find(marker)
    if index < 0:
        fail("{} is not under {}".format(sample, directory))
    return sample[:index + len(marker) - 1]

def _python_env_impl(ctx):
    return [
        PyEnvInfo(
            bin_dir = _dir_of(ctx.files.bin, ctx.attr.bin_dir),
            files = depset(
                [ctx.file.interpreter, ctx.file.uv],
                transitive = [depset(ctx.files.python), depset(ctx.files.site_packages), depset(ctx.files.bin)],
            ),
            interpreter = ctx.file.interpreter,
            site_packages = _dir_of(ctx.files.site_packages, ctx.attr.site_packages_dir),
            source_roots = ctx.attr.source_roots,
            uv = ctx.file.uv,
        ),
    ]

python_env = rule(
    implementation = _python_env_impl,
    doc = "Wraps the files of a python_env_repo in a PyEnvInfo.",
    attrs = {
        "bin": attr.label_list(allow_files = True),
        "bin_dir": attr.string(mandatory = True),
        "interpreter": attr.label(allow_single_file = True, mandatory = True),
        "python": attr.label_list(allow_files = True),
        "site_packages": attr.label_list(allow_files = True),
        "site_packages_dir": attr.string(mandatory = True),
        "source_roots": attr.string_list(),
        "uv": attr.label(allow_single_file = True, mandatory = True),
    },
)

def _python_env_unconfigured_impl(ctx):
    fail(("{}: no Python project is declared. Add to the root MODULE.bazel:\n" +
          "  python = use_extension(\"@tbhb_rules_python//:extensions.bzl\", \"python\")\n" +
          "  python.project()").format(ctx.label))

python_env_unconfigured = rule(
    implementation = _python_env_unconfigured_impl,
    doc = "Stands in for the environment when the root module declares no project.",
)
