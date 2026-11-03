# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`python_env_repo`: a Python environment built from a committed uv.lock.

The environment is what `uv sync` gives a developer: the interpreter uv installs for the project's
Python version, and every locked package of every workspace member and
dependency group, installed without the members themselves (the checks put
their source trees on the path instead). uv verifies each download against
the hashes in uv.lock and in its own interpreter metadata.
"""

load(":versions.bzl", "UV_ASSETS", "UV_PLATFORMS")

# Internal: load //runtime:defs.bzl.
visibility("//runtime/...")

_UNCONFIGURED_BUILD = """\
load("@tbhb_rules//runtime:defs.bzl", "python_env_unconfigured")

python_env_unconfigured(
    name = "env",
    visibility = ["//visibility:public"],
)
"""

_BUILD = """\
load("@tbhb_rules//runtime:defs.bzl", "python_env")

exports_files(["uv"])

python_env(
    name = "env",
    bin = glob(
        ["venv/bin/*"],
        exclude = [
            "venv/bin/activate*",
            "venv/bin/deactivate*",
            "venv/bin/python*",
        ],
    ),
    bin_dir = "venv/bin",
    interpreter = {interpreter},
    python = glob(["python/{install}/**"], exclude = ["**/__pycache__/**"]),
    site_packages = glob(["{site_packages}/**"], exclude = ["**/__pycache__/**"]),
    site_packages_dir = "{site_packages}",
    source_roots = {source_roots},
    uv = "uv",
    visibility = ["//visibility:public"],
)
"""

_PRUNE = """
import sys
from pathlib import Path

NAMES = {"BUILD", "BUILD.bazel", "WORKSPACE", "WORKSPACE.bazel", "MODULE.bazel", "REPO.bazel"}
for top in sys.argv[1:]:
    for path in Path(top).rglob("*"):
        if path.name in NAMES and path.is_file() and not path.is_symlink():
            path.unlink()
"""

def _uv(rctx):
    key = (rctx.os.name, rctx.os.arch)
    if key not in UV_PLATFORMS:
        fail("tbhb_rules has no pinned uv for {} {}".format(*key))
    asset = UV_PLATFORMS[key]
    version, sha256 = UV_ASSETS[asset]
    rctx.download_and_extract(
        url = "https://github.com/astral-sh/uv/releases/download/{}/{}.tar.gz".format(version, asset),
        sha256 = sha256,
        output = "uv-dist",
        strip_prefix = asset,
    )
    rctx.symlink("uv-dist/uv", "uv")
    return rctx.path("uv")

def _run(rctx, args, env, what, working_directory = ""):
    result = rctx.execute(args, environment = env, working_directory = working_directory, quiet = True)
    if result.return_code != 0:
        fail("{}: {} failed ({}):\n{}{}".format(rctx.name, what, result.return_code, result.stdout, result.stderr))
    return result.stdout

def _python_env_repo_impl(rctx):
    if not rctx.attr.lock:
        rctx.file("BUILD.bazel", _UNCONFIGURED_BUILD)
        return

    uv = _uv(rctx)
    lock = rctx.path(rctx.attr.lock)
    pyproject = rctx.path(rctx.attr.pyproject)
    root = pyproject.dirname
    rctx.watch(lock)
    rctx.watch(pyproject)

    version = rctx.attr.python_version
    version_file = root.get_child(".python-version")
    if not version and version_file.exists:
        version = rctx.read(version_file, watch = "yes").strip().splitlines()[0].strip()
    if not version:
        fail("{}: set python_version or commit a .python-version next to {}".format(rctx.name, rctx.attr.pyproject))

    env = {
        "HOME": str(rctx.path("home")),
        "UV_CACHE_DIR": str(rctx.path("uv-cache")),
        "UV_NO_CONFIG": "1",
        "UV_PYTHON_INSTALL_DIR": str(rctx.path("python")),
        "UV_PYTHON_PREFERENCE": "only-managed",
    }
    _run(rctx, [uv, "python", "install", "--no-bin", version], env, "uv python install " + version)
    interpreter = rctx.path(_run(rctx, [uv, "python", "find", version], env, "uv python find").strip()).realpath

    # The members come from the lock, so a workspace needs no per-repo
    # list; uv also needs each member's pyproject.toml to read the
    # workspace, but none of their sources.
    rctx.file("lock_info.py", rctx.read(rctx.attr._lock_info))
    info = json.decode(_run(rctx, [interpreter, "lock_info.py", lock], env, "reading uv.lock"))
    project = rctx.path("project")
    rctx.file("project/pyproject.toml", rctx.read(pyproject))
    rctx.file("project/uv.lock", rctx.read(lock))
    source_roots = []
    for member in info["members"]:
        path = member["path"].rstrip("/")
        if path not in ("", "."):
            member_pyproject = root.get_child(path).get_child("pyproject.toml")
            rctx.file("project/{}/pyproject.toml".format(path), rctx.read(member_pyproject, watch = "yes"))
        if member["kind"] != "editable":
            continue

        # The src layout when the member has one, the flat layout otherwise.
        member_root = root if path in ("", ".") else root.get_child(path)
        if member_root.get_child("src").exists:
            source_roots.append("src" if path in ("", ".") else path + "/src")
        else:
            source_roots.append(path or ".")

    _run(
        rctx,
        [
            uv,
            "sync",
            "--frozen",
            "--all-packages",
            "--all-groups",
            "--no-install-workspace",
            "--link-mode=copy",
            "--no-python-downloads",
            "--python",
            interpreter,
        ],
        dict(env, UV_PROJECT_ENVIRONMENT = str(rctx.path("venv"))),
        "uv sync",
        working_directory = str(project),
    )
    rctx.delete("uv-cache")
    rctx.delete("home")

    # Files that would make a directory a Bazel package or repository
    # boundary (python-build-standalone ships a BUILD file) would cut it out
    # of the globs below.
    _run(rctx, [interpreter, "-c", _PRUNE, "python", "venv"], env, "pruning Bazel files")

    # The interpreter's install directory and its version directory under
    # lib/, both named by uv.
    install = str(interpreter.dirname.dirname.basename)
    lib = [p.basename for p in rctx.path("venv/lib").readdir() if p.basename.startswith("python")]
    if len(lib) != 1:
        fail("{}: expected one python* directory under venv/lib, found {}".format(rctx.name, lib))
    rctx.file("BUILD.bazel", _BUILD.format(
        install = install,
        interpreter = repr("python/{}/bin/{}".format(install, interpreter.basename)),
        site_packages = "venv/lib/{}/site-packages".format(lib[0]),
        source_roots = repr(source_roots),
    ))

python_env_repo = repository_rule(
    implementation = _python_env_repo_impl,
    doc = "The Python environment of a uv project or workspace. See the module docstring.",
    attrs = {
        "lock": attr.label(doc = "The project's uv.lock. Unset makes an environment that fails analysis when used."),
        "pyproject": attr.label(doc = "The root pyproject.toml of the project or workspace."),
        "python_version": attr.string(doc = "The interpreter version; defaults to the first line of .python-version next to pyproject."),
        "_lock_info": attr.label(default = Label(":lock_info.py"), allow_single_file = True),
    },
)
