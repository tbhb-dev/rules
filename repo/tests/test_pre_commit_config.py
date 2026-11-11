# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Keep staged Markdown hooks aligned with the whole-tree gates."""

import ast
import re
import shlex
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
CONFIG = yaml.safe_load((ROOT / ".pre-commit-config.yaml").read_text())
HOOKS = {hook["id"]: hook for repo in CONFIG["repos"] for hook in repo["hooks"]}


def _call(path: str, function: str, name: str | None = None) -> ast.Call:
    tree = ast.parse((ROOT / path).read_text())
    return next(
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id == function
        and (
            name is None
            or any(
                kw.arg == "name" and ast.literal_eval(kw.value) == name
                for kw in node.keywords
            )
        )
    )


@pytest.mark.parametrize(
    ("tool", "build", "prefix", "flags", "label"),
    [
        (
            "vale",
            "tools/BUILD.bazel",
            [],
            ["--no-wrap"],
            "@tbhb_rules_vale//:vale",
        ),
        (
            "cspell",
            "BUILD.bazel",
            ["env", "BAZEL_BINDIR=."],
            ["lint", "--no-progress", "--dot"],
            "//lint/private/cspell",
        ),
        (
            "rumdl",
            "BUILD.bazel",
            [],
            ["check"],
            "@tbhb_rules_rumdl//:rumdl",
        ),
    ],
)
def test_markdown_hooks_match_gates(
    tool: str,
    build: str,
    prefix: list[str],
    flags: list[str],
    label: str,
) -> None:
    hook = HOOKS[tool]
    assert hook["language"] == "system"
    assert hook["stages"] == ["pre-commit"]
    assert hook["pass_filenames"] is True
    assert hook["types"] == ["markdown"]
    assert not hook.get("always_run", False)
    gate = _call(build, f"{tool}_test", f"{tool}_test")
    config = next(
        ast.literal_eval(kw.value) for kw in gate.keywords if kw.arg == "config"
    )
    config = config.removeprefix("//:")
    assert (ROOT / config).is_file()
    args = shlex.split(hook["entry"])
    expected = [*prefix, f"tools/.bazel_env/bin/{tool}", *flags, "--config", config]
    # Vale's gate uses --config=FILE; normalize it for comparison.
    args = [
        part
        for arg in args
        for part in (
            ["--config", arg.removeprefix("--config=")]
            if arg.startswith("--config=")
            else [arg]
        )
    ]
    assert sorted(args) == sorted(expected)
    assert not hook.get("args")
    shims = _call("tools/BUILD.bazel", "bazel_env")
    tools = next(
        ast.literal_eval(kw.value) for kw in shims.keywords if kw.arg == "tools"
    )
    assert tools[tool] == label
    package, _, _ = label.removeprefix("//").partition(":")
    if label.startswith("//"):
        assert (ROOT / package / "BUILD.bazel").is_file()


def test_gate_flags() -> None:
    # Detect upstream macro changes that need a corresponding hook update.
    spelling = (ROOT / "lint/private/cspell.bzl").read_text()
    assert 'tool_args = ["lint", "--no-progress", "--dot"]' in spelling
    assert '["--config", "{config}"]' in spelling
    assert 'env.setdefault("BAZEL_BINDIR", ".")' in spelling
    markdown = (ROOT / "lint/private/checks.bzl").read_text()
    assert (
        'tool_args = ["check"] + _config_args(config, "--config") + ["."]' in markdown
    )
    vale = (ROOT / "lint/private/vale.sh").read_text()
    assert 'exec vale --config="$config" --no-wrap "${files[@]}"' in vale


@pytest.mark.parametrize(
    "path", ["README.md", "docs/reference/frontmatter.md", ".github/notes.md"]
)
def test_markdown_paths_are_included(path: str) -> None:
    assert re.search(CONFIG["exclude"], path) is None


def test_pre_push_gate_is_kept() -> None:
    hook = HOOKS["spelling-and-prose"]
    assert hook["entry"] == "bazelisk test //:cspell_test //tools:vale_test"
    assert hook["stages"] == ["pre-push"]
    assert hook["always_run"] is True
    assert hook["pass_filenames"] is False
