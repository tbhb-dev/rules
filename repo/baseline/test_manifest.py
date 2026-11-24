# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import json
import re
import tomllib
from pathlib import Path

import pytest
import yaml
from jsonschema import Draft202012Validator, ValidationError

from repo.baseline.check_manifest import check_manifest

ROOT = Path(__file__).parent
WORKFLOWS = ROOT.parents[1] / ".github" / "workflows"
PR_ONLY = "github.event_name == 'pull_request'"
PR_EXPRESSION = re.compile(r"\$\{\{([^}]*github\.event\.pull_request\.[^}]*)\}\}")
PR_WITH_FALLBACK = re.compile(
    r"github\.event\.pull_request\.[\w.]+ \|\| "
    r"github\.(?:sha|event\.merge_group\.base_sha \|\| github\.event\.before)"
)


def test_baseline() -> None:
    check_manifest(ROOT)


def test_commit_msg_hooks_match_seed_configs() -> None:
    manifest = tomllib.loads((ROOT / "manifest.toml").read_text())
    for kind in manifest["kinds"]:
        seed = ROOT / "seed" / kind / "pre-commit-config.yaml"
        config = yaml.safe_load(seed.read_text())
        hooks = {
            hook["id"]
            for repo in config["repos"]
            for hook in repo["hooks"]
            if "commit-msg" in hook.get("stages", [])
        }
        assert hooks == set(manifest["kind"][kind]["hooks"]["commit-msg"]), kind


@pytest.mark.parametrize("kind", ["rules", "chezmoi", "docs", "go", "python"])
def test_ci_runs_on_merge_group(kind: str) -> None:
    directory = (
        WORKFLOWS if kind == "rules" else ROOT / "seed" / kind / ".github" / "workflows"
    )
    # Read the key before YAML can coerce `on` to a boolean.
    workflow: object = yaml.compose(
        (directory / "ci.yml").read_text(encoding="utf-8"), Loader=yaml.SafeLoader
    )
    assert isinstance(workflow, yaml.MappingNode)
    events = next(value for key, value in workflow.value if key.value == "on")
    assert isinstance(events, yaml.MappingNode)
    merge_group = next(
        value for key, value in events.value if key.value == "merge_group"
    )
    assert yaml.safe_load(yaml.serialize(merge_group)) == {
        "types": ["checks_requested"]
    }


@pytest.mark.parametrize("name", ["ci.yml", "repo-checks.yml", "pr-text.yml"])
def test_pull_request_context_has_a_guard(name: str) -> None:
    workflow = yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))
    for job in workflow["jobs"].values():
        if job.get("if") == PR_ONLY:
            continue
        steps = job.pop("steps", [])
        for scope in [job, *steps]:
            if scope.get("if") == PR_ONLY:
                continue
            source = yaml.safe_dump(scope, width=1000)
            for match in PR_EXPRESSION.findall(source):
                expression = match.strip()
                assert expression.startswith(
                    f"{PR_ONLY} && "
                ) or PR_WITH_FALLBACK.fullmatch(expression), expression


@pytest.mark.parametrize(
    "name", [".pre-commit-config.yaml", ".pre-commit-config.yml", "prek.toml"]
)
def test_no_live_hook_configs(name: str) -> None:
    assert not list(ROOT.rglob(name))


@pytest.fixture
def baseline(tmp_path: Path) -> Path:
    (tmp_path / "manifest.schema.json").write_bytes(
        (ROOT / "manifest.schema.json").read_bytes()
    )
    (tmp_path / "manifest.toml").write_text(
        'schema_version = 1\nkinds = ["go", "docs"]\n'
        'placeholders = ["repo_name"]\nnever_write = []\n'
        '[[file]]\npath = "config.toml"\nsource = "config.toml"\n'
        'mode = "keys"\nkeys = ["settings.locked"]\n'
        "[kind.go]\nrequired = []\n"
    )
    (tmp_path / "config.toml").write_text("[settings]\nlocked = true\n")
    return tmp_path


def replace_manifest(root: Path, before: str, after: str) -> None:
    path = root / "manifest.toml"
    path.write_text(path.read_text().replace(before, after))


def test_minimal_manifest(baseline: Path) -> None:
    check_manifest(baseline)


@pytest.mark.parametrize(
    ("before", "after", "error", "message"),
    [
        ("schema_version = 1", "schema_version = 2", ValidationError, "1 was expected"),
        (
            'source = "config.toml"',
            'source = "absent.toml"',
            FileNotFoundError,
            "absent",
        ),
        ("[kind.go]", "[kind.other]", ValueError, "Unknown kind tables"),
        (
            'mode = "keys"',
            'kinds = ["other"]\nmode = "keys"',
            ValueError,
            "Unknown entry kinds",
        ),
        ("settings.locked", "settings.absent", KeyError, "absent"),
        ('keys = ["settings.locked"]', "keys = []", ValidationError, "non-empty"),
        (
            'keys = ["settings.locked"]',
            'keys = ["settings.locked"]\ntemplate = true',
            ValueError,
            "Undeclared placeholders",
        ),
    ],
)
def test_defects(
    baseline: Path, before: str, after: str, error: type[Exception], message: str
) -> None:
    replace_manifest(baseline, before, after)
    (baseline / "config.toml").write_text("# {{other}}\n[settings]\nlocked = true\n")
    with pytest.raises(error, match=message):
        check_manifest(baseline)


@pytest.mark.parametrize(
    "suffix",
    ["toml", "json", "yaml", "yml", "toml.baseline", "json.baseline", "yaml.baseline"],
)
def test_key_formats(baseline: Path, suffix: str) -> None:
    replace_manifest(baseline, 'source = "config.toml"', f'source = "config.{suffix}"')
    value = {
        "toml": "[settings]\nlocked = true\n",
        "json": '{"settings": {"locked": true}}',
    }
    (baseline / f"config.{suffix}").write_text(
        value.get(suffix.removesuffix(".baseline"), "settings:\n  locked: true\n")
    )
    check_manifest(baseline)


@pytest.mark.parametrize("visibility", ["all", "public", "private"])
def test_duplicate_destinations(baseline: Path, visibility: str) -> None:
    with (baseline / "manifest.toml").open("a") as stream:
        stream.write(
            '\n[[file]]\npath = "config.toml"\nsource = "config.toml"\n'
            f'mode = "bytes"\nvisibility = "{visibility}"\nkinds = ["go"]\n'
        )
    with pytest.raises(ValueError, match="Repeated destination"):
        check_manifest(baseline)


@pytest.mark.parametrize(("first", "second"), [("public", "private"), ("go", "docs")])
def test_disjoint_destinations(baseline: Path, first: str, second: str) -> None:
    selector = "visibility" if first == "public" else "kinds"
    value = f'"{first}"' if selector == "visibility" else f'["{first}"]'
    replace_manifest(baseline, 'mode = "keys"', f'{selector} = {value}\nmode = "keys"')
    value = f'"{second}"' if selector == "visibility" else f'["{second}"]'
    with (baseline / "manifest.toml").open("a") as stream:
        stream.write(
            '\n[[file]]\npath = "config.toml"\nsource = "config.toml"\n'
            f'mode = "bytes"\n{selector} = {value}\n'
        )
    check_manifest(baseline)


@pytest.mark.parametrize(
    "token", ["other", " repo_name ", "repo_name | upper", "bad\nname"]
)
def test_invalid_template_tokens(baseline: Path, token: str) -> None:
    replace_manifest(
        baseline,
        'mode = "keys"\nkeys = ["settings.locked"]',
        'template = true\nmode = "bytes"',
    )
    (baseline / "config.toml").write_text(
        "# {{" + token + "}}\n[settings]\nlocked = true\n"
    )
    with pytest.raises(ValueError, match="Undeclared placeholders"):
        check_manifest(baseline)


def test_github_expressions_and_declared_placeholder(baseline: Path) -> None:
    replace_manifest(baseline, 'mode = "keys"', 'template = true\nmode = "keys"')
    (baseline / "config.toml").write_text(
        "# {{repo_name}} ${{ matrix.os }}\n[settings]\nlocked = true\n"
    )
    check_manifest(baseline)


@pytest.mark.parametrize(
    "declaration",
    [
        {"schema_version": 2, "kind": "go", "private": False},
        {"schema_version": 1, "kind": "other", "private": False},
        {"schema_version": 1, "kind": "go", "private": "false"},
        {
            "schema_version": 1,
            "kind": "go",
            "private": False,
            "exception": [{"check": "C2", "path": ".bazelversion", "reason": "  "}],
        },
    ],
)
def test_invalid_consumer_declarations(declaration: dict[str, object]) -> None:
    schema = json.loads((ROOT / "repo.schema.json").read_text())
    Draft202012Validator.check_schema(schema)
    with pytest.raises(ValidationError):
        Draft202012Validator(schema).validate(declaration)


def test_consumer_declaration() -> None:
    schema = json.loads((ROOT / "repo.schema.json").read_text())
    Draft202012Validator(schema).validate(
        {
            "schema_version": 1,
            "kind": "chezmoi",
            "private": True,
            "exception": [
                {"check": "C2", "path": ".bazelversion", "reason": "Pin transition"}
            ],
        }
    )
