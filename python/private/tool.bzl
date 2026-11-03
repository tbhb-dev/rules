# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`python_tool` with the root module's environment as its default."""

load("@tbhb_rules//runtime:defs.bzl", _python_tool = "python_tool")

# Internal: consumers load //:defs.bzl.
visibility("//...")

DEFAULT_ENV = Label("@tbhb_python//:env")
TOOLS_ENV = Label("@tbhb_python_tools//:env")

def python_tool(name, python_env = DEFAULT_ENV, **kwargs):
    """An executable that runs one tool of a locked Python environment.

    See `@tbhb_rules//runtime:defs.bzl`. The environment defaults to the
    root module's (`@tbhb_python//:env`).

    Args:
        name: Target name.
        python_env: The environment.
        **kwargs: Passed to tbhb_rules' `python_tool`.
    """
    _python_tool(name = name, python_env = python_env, **kwargs)
