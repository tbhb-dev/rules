# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The hint for an interpreter that does not satisfy the project's requires-python."""

# Internal: load //runtime:defs.bzl.
visibility("//runtime/...")

# uv prints this when the interpreter does not satisfy requires-python.
_INCOMPATIBLE = "incompatible with the project's Python requirement"

def _requires_python(pyproject):
    """The `requires-python` of the `[project]` table, or None when absent."""
    in_project = False
    for line in pyproject.splitlines():
        line = line.strip()
        if line.startswith("["):
            in_project = line == "[project]"
        elif in_project and line.startswith("requires-python"):
            parts = line.split("=", 1)
            if len(parts) == 2 and parts[0].strip() == "requires-python":
                return parts[1].split("#")[0].strip().strip("\"'")
    return None

def python_mismatch_hint(stderr, version, pyproject):
    """The hint to append to a failed `uv sync`, empty for any other failure.

    Args:
        stderr: The stderr of the failed command.
        version: The interpreter version from `.python-version` or `python_version`.
        pyproject: The text of the project's pyproject.toml.

    Returns:
        The hint, or an empty string when stderr is not an incompatibility.
    """
    if _INCOMPATIBLE not in stderr:
        return ""
    requires = _requires_python(pyproject)
    return """
The interpreter is Python {version} (from .python-version or the python_version
attribute), and {requires}. Bump .python-version, or set python_version on the
toolchain tag, to a version that satisfies requires-python.
""".format(
        version = version,
        requires = "the project's requires-python is " + requires if requires else "pyproject.toml has no requires-python under [project]",
    )
