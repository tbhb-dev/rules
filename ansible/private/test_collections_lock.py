# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import io
import json
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from private import collections_lock

SHA = "0" * 64
URL = "https://galaxy.ansible.com/api/v3/plugin/ansible/content/published/collections/artifacts/x.tar.gz"


def pin(**fields: object) -> dict[str, object]:
    return {
        "name": "ansible.posix",
        "version": "2.2.2",
        "source": collections_lock.GALAXY,
    } | fields


@pytest.mark.parametrize(
    ("entry", "message"),
    [
        ("ansible.posix", "give each collection as a mapping"),
        (pin(name="Ansible-Posix"), "is not a collection name"),
        (pin(name=None), "None is not a collection name"),
        (pin(signatures=[]), "unsupported keys signatures"),
        (pin(version=">=2.0.0"), "'>=2.0.0' is not one exact version"),
        (pin(version=2), "2 is not one exact version"),
        (
            pin(source="https://example.com"),
            "source must be https://galaxy.ansible.com",
        ),
        (pin(type="git"), "type must be galaxy, not 'git'"),
    ],
)
def test_entry_pin_rejects(entry: object, message: str) -> None:
    with pytest.raises(collections_lock.LockError, match=message):
        collections_lock.entry_pin(entry)


@pytest.mark.parametrize(
    "entry", [pin(), pin(type="galaxy"), pin(version="1.0.0-rc.1+build.5")]
)
def test_entry_pin_accepts(entry: dict[str, object]) -> None:
    assert collections_lock.entry_pin(entry) == ("ansible.posix", entry["version"])


def write(path: Path, text: str) -> Path:
    path.write_text(text, encoding="utf-8")
    return path


@pytest.mark.parametrize(
    ("text", "message"),
    [
        ("- ansible.posix\n", "expected a mapping"),
        ("roles:\n  - name: example.role\n", "roles are not supported"),
        ("collections: []\n", "non-empty `collections` list"),
        ("collections: ansible.posix\n", "non-empty `collections` list"),
    ],
)
def test_read_pins_rejects(tmp_path: Path, text: str, message: str) -> None:
    with pytest.raises(collections_lock.LockError, match=message):
        collections_lock.read_pins(write(tmp_path / "requirements.yml", text))


REQUIREMENTS = """\
collections:
  - name: ansible.posix
    version: 2.2.2
    source: https://galaxy.ansible.com
  - name: community.general
    version: "12.0.0"
    source: https://galaxy.ansible.com
"""


def test_read_pins(tmp_path: Path) -> None:
    path = write(tmp_path / "requirements.yml", "roles: []\n" + REQUIREMENTS)
    assert collections_lock.read_pins(path) == {
        "ansible.posix": "2.2.2",
        "community.general": "12.0.0",
    }


def test_read_pins_rejects_duplicates(tmp_path: Path) -> None:
    path = write(
        tmp_path / "requirements.yml",
        REQUIREMENTS + REQUIREMENTS.removeprefix("collections:\n"),
    )
    with pytest.raises(
        collections_lock.LockError, match=r"ansible\.posix is listed more than once"
    ):
        collections_lock.read_pins(path)


def test_galaxy_get(monkeypatch: pytest.MonkeyPatch) -> None:
    seen: list[urllib.request.Request] = []

    def fake_urlopen(request: urllib.request.Request, timeout: int) -> io.BytesIO:
        assert timeout == collections_lock.TIMEOUT
        seen.append(request)
        return io.BytesIO(b'{"ok": true}')

    monkeypatch.setattr(collections_lock.urllib.request, "urlopen", fake_urlopen)
    assert collections_lock.galaxy_get("https://galaxy.ansible.com/x/") == {"ok": True}
    assert seen[0].get_header("User-agent") == "tbhb_rules_ansible-lock"


def test_galaxy_get_wraps_url_errors(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_urlopen(*_args: object, **_kwargs: object) -> io.BytesIO:
        reason = "unreachable"
        raise urllib.error.URLError(reason)

    monkeypatch.setattr(collections_lock.urllib.request, "urlopen", fake_urlopen)
    with pytest.raises(
        collections_lock.LockError,
        match=r"https://galaxy\.ansible\.com/x/: .*unreachable",
    ):
        collections_lock.galaxy_get("https://galaxy.ansible.com/x/")


def answer(sha256: object = SHA, url: object = URL) -> dict[str, object]:
    return {"artifact": {"sha256": sha256}, "download_url": url}


def test_lock_entry_asks_for_the_exact_version() -> None:
    asked: list[str] = []

    def fetch(url: str) -> object:
        asked.append(url)
        return answer()

    assert collections_lock.lock_entry("ansible.posix", "2.2.2", fetch) == {
        "sha256": SHA,
        "url": URL,
        "version": "2.2.2",
    }
    assert asked == [
        (
            "https://galaxy.ansible.com/api/v3/plugin/ansible/content/published/"
            "collections/index/ansible/posix/versions/2.2.2/"
        )
    ]


@pytest.mark.parametrize(
    ("reply", "message"),
    [
        ([], "not a JSON object"),
        ({"artifact": None, "download_url": URL}, "no sha256"),
        (answer(sha256="ABC"), "no sha256"),
        (answer(url="http://example.com/x.tar.gz"), "no https download URL"),
        (answer(url=None), "no https download URL"),
    ],
)
def test_lock_entry_rejects(reply: object, message: str) -> None:
    with pytest.raises(collections_lock.LockError, match=message):
        collections_lock.lock_entry("ansible.posix", "2.2.2", lambda _: reply)


def test_render_is_sorted_with_a_trailing_newline() -> None:
    text = collections_lock.render(
        {"b.c": {"version": "1.0.0", "sha256": SHA, "url": URL}, "a.b": {}}
    )
    assert text.endswith("}\n")
    assert text.index('"a.b"') < text.index('"b.c"')
    assert text.index('"sha256"') < text.index('"url"') < text.index('"version"')


LOCKED = {"sha256": SHA, "url": URL, "version": "2.2.2"}


@pytest.mark.parametrize(
    ("document", "problems"),
    [
        ([], ["lock.json: expected a `collections` object"]),
        ({"collections": []}, ["lock.json: expected a `collections` object"]),
        ({"collections": {"ansible.posix": LOCKED}}, []),
        (
            {"collections": {"ansible.utils": LOCKED}},
            [
                "ansible.posix is pinned but not locked",
                "ansible.utils is locked but not pinned",
            ],
        ),
        (
            {"collections": {"ansible.posix": LOCKED | {"version": "2.2.1"}}},
            ["ansible.posix is pinned at 2.2.2 but locked at '2.2.1'"],
        ),
        (
            {"collections": {"ansible.posix": "2.2.2"}},
            ["ansible.posix is pinned at 2.2.2 but locked at None"],
        ),
        (
            {"collections": {"ansible.posix": {"version": "2.2.2", "url": URL}}},
            ["ansible.posix has no url and sha256 in the lock"],
        ),
        (
            {"collections": {"ansible.posix": {"version": "2.2.2", "sha256": SHA}}},
            ["ansible.posix has no url and sha256 in the lock"],
        ),
    ],
)
def test_check(tmp_path: Path, document: object, problems: list[str]) -> None:
    path = write(tmp_path / "lock.json", json.dumps(document))
    found = collections_lock.check({"ansible.posix": "2.2.2"}, path)
    assert [p.replace(str(path), "lock.json") for p in found] == problems


def test_check_without_a_lock(tmp_path: Path) -> None:
    assert collections_lock.check({}, tmp_path / "lock.json") == [
        f"{tmp_path / 'lock.json'} does not exist"
    ]


def test_resolve(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("BUILD_WORKSPACE_DIRECTORY", raising=False)
    assert collections_lock.resolve("a/b.yml") == Path("a/b.yml")
    monkeypatch.setenv("BUILD_WORKSPACE_DIRECTORY", "/work")
    assert collections_lock.resolve("a/b.yml") == Path("/work/a/b.yml")


@pytest.fixture
def workspace(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setenv("BUILD_WORKSPACE_DIRECTORY", str(tmp_path))
    (tmp_path / "ansible").mkdir()
    write(tmp_path / "ansible/requirements.yml", REQUIREMENTS)
    return tmp_path


ARGS = [
    "--requirements",
    "ansible/requirements.yml",
    "--lock",
    "ansible/requirements.lock.json",
]


def fake_galaxy(url: str) -> object:
    return answer(url=URL.replace("x", url.split("/")[-4]))


def test_main_without_collections(capsys: pytest.CaptureFixture[str]) -> None:
    assert collections_lock.main(["--requirements=", "--lock="]) == 1
    assert "no collections to lock" in capsys.readouterr().err


def test_main_writes_the_lock_and_a_rerun_is_identical(
    workspace: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    lock = workspace / "ansible/requirements.lock.json"
    assert collections_lock.main(ARGS, fetch=fake_galaxy) == 0
    first = lock.read_bytes()
    assert b"\r" not in first
    assert sorted(json.loads(first)["collections"]) == [
        "ansible.posix",
        "community.general",
    ]
    assert "wrote" in capsys.readouterr().out
    assert collections_lock.main(ARGS, fetch=fake_galaxy) == 0
    assert lock.read_bytes() == first
    assert sorted(workspace.rglob("*")) == [
        workspace / "ansible",
        lock,
        workspace / "ansible/requirements.yml",
    ]


@pytest.mark.usefixtures("workspace")
def test_main_check(capsys: pytest.CaptureFixture[str]) -> None:
    assert collections_lock.main([*ARGS, "--check"]) == 1
    err = capsys.readouterr().err
    assert "does not exist" in err
    assert (
        "Run `bazelisk run @tbhb_rules_ansible//:lock` from the repository root" in err
    )
    assert collections_lock.main(ARGS, fetch=fake_galaxy) == 0
    assert collections_lock.main([*ARGS, "--check"]) == 0
    assert "matches" in capsys.readouterr().out


@pytest.mark.usefixtures("workspace")
def test_main_reports_lock_errors_without_writing(
    capsys: pytest.CaptureFixture[str],
) -> None:
    assert collections_lock.main(ARGS, fetch=lambda _: {}) == 1
    assert "FAIL: ansible.posix 2.2.2: Galaxy gave no sha256" in capsys.readouterr().err
