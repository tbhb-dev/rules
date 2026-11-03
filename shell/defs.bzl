# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Helpers for rules whose executable is a generated Bash script."""

load(
    "//shell/private:launcher.bzl",
    _SHELL_ATTRS = "SHELL_ATTRS",
    _SHELL_TOOLCHAINS = "SHELL_TOOLCHAINS",
    _is_windows = "is_windows",
    _shell_executable = "shell_executable",
)

SHELL_ATTRS = _SHELL_ATTRS
SHELL_TOOLCHAINS = _SHELL_TOOLCHAINS
is_windows = _is_windows
shell_executable = _shell_executable
