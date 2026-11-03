# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Python runtime shared by tbhb_rules' own Python checks and tbhb_rules_python.

A `python_env_repo` is what `uv sync` gives a developer, built from a
committed uv.lock with the pinned uv; `python_tool` runs one of its tools.
The repository rules generated environments call `python_env` and
`python_env_unconfigured` from here too.
"""

load("//runtime/private:env.bzl", _python_tool = "python_tool")
load(
    "//runtime/private:env_info.bzl",
    _PyEnvInfo = "PyEnvInfo",
    _python_env = "python_env",
    _python_env_unconfigured = "python_env_unconfigured",
)
load("//runtime/private:repo.bzl", _python_env_repo = "python_env_repo")

PyEnvInfo = _PyEnvInfo
python_env = _python_env
python_env_repo = _python_env_repo
python_env_unconfigured = _python_env_unconfigured
python_tool = _python_tool
