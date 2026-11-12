# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`python_env_repo`: a Python environment built from a committed uv.lock.

The environment is what `uv sync` gives a developer: the interpreter uv installs for the project's
Python version, and every locked package of every workspace member and
dependency group, installed without the members themselves (the checks put
their source trees on the path instead). uv verifies each download against
the hashes in uv.lock and in its own interpreter metadata.
"""

load(":python_mismatch.bzl", "python_mismatch_hint")
load(":python_sync.bzl", "python_sync_retry")
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

exports_files(["{uv}"])

python_env(
    name = "env",
    bin = glob(
        ["{bin}/*"],
        exclude = [
            "{bin}/activate*",
            "{bin}/deactivate*",
            "{bin}/python*",
            "{bin}/*.ps1",
        ],
    ),
    bin_dir = "{bin}",
    interpreter = {interpreter},
    members = {members},
    python = glob(["python/{install}/**"], exclude = ["**/__pycache__/**"]),
    site_packages = glob(["{site_packages}/**"], exclude = ["**/__pycache__/**"]),
    site_packages_dir = "{site_packages}",
    source_roots = {source_roots},
    uv = "{uv}",
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
    windows = rctx.os.name.startswith("windows")
    key = ("windows" if windows else rctx.os.name, rctx.os.arch)
    if key not in UV_PLATFORMS:
        fail("tbhb_rules has no pinned uv for {} {}".format(rctx.os.name, rctx.os.arch))
    asset = UV_PLATFORMS[key]
    url, sha256 = UV_ASSETS[asset]
    rctx.download_and_extract(
        url = url,
        sha256 = sha256,
        output = "uv-dist",
        # The Windows zip holds uv.exe at its top level.
        strip_prefix = "" if windows else asset,
    )
    if windows:
        return rctx.path("uv-dist/uv.exe")
    rctx.symlink("uv-dist/uv", "uv")
    return rctx.path("uv")

# uv prints this when a locked package has no wheel for the interpreter and
# platform, and building its sdist failed.
_SDIST_BUILD_FAILED = "Failed to build `"

_SDIST_HINT = """
A package in uv.lock has no wheel for this Python version and platform, so uv
built it from source, and that build needs tools this host lacks (a C
compiler, make or Rust). Skip the package on this Python version with an
environment marker in pyproject.toml, or lock a version that publishes a
wheel for it.
"""

# A progressing wheel body can evade uv's idle-read timeout. Three 150 s
# attempts allow ~120 s for a 17 MB wheel at 145 KB/s, yet cap sync at 450 s:
# below the shared repo-checks 8-minute retry budget, with 150 s left in a
# 10-minute CI job for setup and other work (the workflow defaults to 15).
_SYNC_TIMEOUT = 150
_SYNC_ATTEMPTS = 3

def _check_result(rctx, result, what, mismatch = None, timeout_hint = ""):
    if result.return_code != 0:
        hint = _SDIST_HINT if _SDIST_BUILD_FAILED in result.stderr else ""
        if mismatch:
            hint += python_mismatch_hint(result.stderr, mismatch[0], mismatch[1])
        hint += timeout_hint
        fail("{}: {} failed ({}):\n{}{}{}".format(rctx.name, what, result.return_code, result.stdout, result.stderr, hint))
    return result.stdout

def _run(rctx, args, env, what, working_directory = ""):
    result = rctx.execute(args, environment = env, working_directory = working_directory, quiet = True)
    return _check_result(rctx, result, what)

def _run_sync(rctx, args, env, working_directory, mismatch):
    for attempt in range(1, _SYNC_ATTEMPTS + 1):
        result = rctx.execute(
            args,
            environment = env,
            working_directory = working_directory,
            quiet = True,
            timeout = _SYNC_TIMEOUT,
        )
        decision = python_sync_retry(result.return_code, result.stderr, attempt, _SYNC_ATTEMPTS, _SYNC_TIMEOUT)
        if not decision.retry:
            return _check_result(rctx, result, "uv sync", mismatch, decision.hint)

        # Keep uv-cache: completed, validated wheels survive a killed attempt;
        # the next sync downloads the unfinished wheels again.
        rctx.report_progress("uv sync timed out after {} s; retrying ({}/{})".format(_SYNC_TIMEOUT, attempt + 1, _SYNC_ATTEMPTS))
    fail("uv sync exceeded its retry limit")

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

    # A package without a wheel for this platform builds from source, and a
    # Rust one (maturin) runs rustup and cargo, which look under HOME unless
    # RUSTUP_HOME and CARGO_HOME say otherwise. HOME above is private, so
    # point them at the user's own toolchain. getenv also makes Bazel fetch this
    # environment again when they change.
    user_home = rctx.getenv("HOME")
    for name, default in [("RUSTUP_HOME", ".rustup"), ("CARGO_HOME", ".cargo")]:
        value = rctx.getenv(name) or (user_home + "/" + default if user_home else None)
        if value:
            env[name] = value
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
    members = []
    for member in info["members"]:
        path = member["path"].rstrip("/")
        if path not in ("", "."):
            member_pyproject = root.get_child(path).get_child("pyproject.toml")
            rctx.file("project/{}/pyproject.toml".format(path), rctx.read(member_pyproject, watch = "yes"))
        if member["kind"] != "editable":
            continue
        members.append(path or ".")

        # The src layout when the member has one, the flat layout otherwise.
        member_root = root if path in ("", ".") else root.get_child(path)
        if member_root.get_child("src").exists:
            source_roots.append("src" if path in ("", ".") else path + "/src")
        else:
            source_roots.append(path or ".")

    _run_sync(
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
        # Explicit HTTP limits handle idle reads and connection failures.
        # They cannot stop a slowly progressing wheel; _run_sync bounds it.
        dict(
            env,
            UV_HTTP_CONNECT_TIMEOUT = "10",
            UV_HTTP_RETRIES = "3",
            UV_HTTP_TIMEOUT = "30",
            UV_PROJECT_ENVIRONMENT = str(rctx.path("venv")),
        ),
        working_directory = str(project),
        mismatch = (version, rctx.read(pyproject)),
    )
    rctx.delete("uv-cache")
    rctx.delete("home")

    # Files that would make a directory a Bazel package or repository
    # boundary (python-build-standalone ships a BUILD file) would cut it out
    # of the globs below.
    _run(rctx, [interpreter, "-c", _PRUNE, "python", "venv"], env, "pruning Bazel files")

    # The interpreter's install directory, named by uv, and the venv's
    # layout: python.exe at the install root, venv/Scripts and
    # venv/Lib/site-packages on Windows; bin/python3.X, venv/bin and
    # venv/lib/python3.X/site-packages elsewhere.
    windows = rctx.os.name.startswith("windows")
    if windows:
        install = str(interpreter.dirname.basename)
        executable = "python/{}/{}".format(install, interpreter.basename)
        bin = "venv/Scripts"
        site_packages = "venv/Lib/site-packages"
    else:
        install = str(interpreter.dirname.dirname.basename)
        executable = "python/{}/bin/{}".format(install, interpreter.basename)
        bin = "venv/bin"
        lib = [p.basename for p in rctx.path("venv/lib").readdir() if p.basename.startswith("python")]
        if len(lib) != 1:
            fail("{}: expected one python* directory under venv/lib, found {}".format(rctx.name, lib))
        site_packages = "venv/lib/{}/site-packages".format(lib[0])
    if not rctx.path(executable).exists:
        fail("{}: the interpreter is not at {}".format(rctx.name, executable))
    rctx.file("BUILD.bazel", _BUILD.format(
        bin = bin,
        install = install,
        interpreter = repr(executable),
        site_packages = site_packages,
        source_roots = repr(source_roots),
        members = repr(members),
        uv = "uv-dist/uv.exe" if windows else "uv",
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
