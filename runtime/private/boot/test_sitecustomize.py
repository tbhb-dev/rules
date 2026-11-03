# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import runpy
import site
from pathlib import Path

import pytest

SITECUSTOMIZE = Path(__file__).with_name("sitecustomize.py")


def run(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    added: list[str] = []
    monkeypatch.setattr(site, "addsitedir", added.append)
    runpy.run_path(str(SITECUSTOMIZE))
    return added


def test_adds_the_named_site_packages(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TBHB_PYTHON_SITE_PACKAGES", "/env/site-packages")
    assert run(monkeypatch) == ["/env/site-packages"]


@pytest.mark.parametrize("value", [None, ""])
def test_does_nothing_without_one(
    monkeypatch: pytest.MonkeyPatch,
    value: str | None,
) -> None:
    if value is None:
        monkeypatch.delenv("TBHB_PYTHON_SITE_PACKAGES", raising=False)
    else:
        monkeypatch.setenv("TBHB_PYTHON_SITE_PACKAGES", value)
    assert run(monkeypatch) == []
