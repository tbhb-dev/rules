# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

import ast
import sys
lazy from pathlib import Path

import pytest

from lint.private.mutation_oses import check_mutation_oses as checker


@pytest.mark.parametrize(
    ("filename", "text", "expected"),
    [
        ("a.go", "package a", set()),
        ("a.py", "answer = 42", set()),
        ("a_linux.go", "", {"linux"}),
        ("a_darwin.go", "", {"macos"}),
        ("a_windows.go", "", {"windows"}),
        ("a_unix.go", "", {"linux", "macos"}),
        ("a_windows_amd64.go", "", {"windows"}),
        ("a_darwin_arm64_test.go", "", {"macos"}),
        ("a_linux_test.go", "", {"linux"}),
        ("a_unix_amd64.go", "", {"linux", "macos"}),
        ("a.go", "runtime.GOOS", {"linux", "macos", "windows"}),
        ("a.go", "filepath.Separator", {"linux", "macos", "windows"}),
        ("a.go", "os.PathSeparator", {"linux", "macos", "windows"}),
        ("a.go", "os.Chmod(path, 0o700)", {"linux", "macos", "windows"}),
        ("a.go", "os.FileMode(0o700)", {"linux", "macos", "windows"}),
        ("a.go", "info.Mode().Perm()", {"linux", "macos", "windows"}),
        ("a.go", 'import "os/exec"', {"linux", "macos", "windows"}),
        ("a.go", "syscall.Kill", {"linux", "macos", "windows"}),
        ("a.go", 'import "os/signal"', {"linux", "macos", "windows"}),
        ("a.py", "sys.platform", {"linux", "macos", "windows"}),
        ("a.py", "os.name", {"linux", "macos", "windows"}),
        ("a.py", "platform.system()", {"linux", "macos", "windows"}),
        ("a.py", "os.chmod(path, 0o700)", {"linux", "macos", "windows"}),
        ("a.py", "import subprocess", {"linux", "macos", "windows"}),
        ("a.py", "from signal import SIGINT", {"linux", "macos", "windows"}),
        ("a.py", "os.path.join('a', 'b')", {"linux", "macos", "windows"}),
        ("a.py", "posixpath.join('a', 'b')", {"linux", "macos", "windows"}),
        ("a.py", "ntpath.join('a', 'b')", {"linux", "macos", "windows"}),
        ("a.py", "pathlib.PureWindowsPath('C:/')", {"windows"}),
        ("a.py", "pathlib.WindowsPath('C:/')", {"windows"}),
        ("a.py", "runtime.GOOS", set()),
        ("a.go", "sys.platform", set()),
        ("a.go", "//go:build linux\n", {"linux"}),
        ("a.go", "//go:build darwin\n", {"macos"}),
        ("a.go", "//go:build windows\n", {"windows"}),
        ("a.go", "//go:build unix\n", {"linux", "macos"}),
        ("a.go", "//go:build !windows\n", {"linux", "macos"}),
        (
            "a.go",
            "//go:build (linux || darwin) && arm64\nruntime.GOOS",
            {"linux", "macos"},
        ),
        ("a.go", "//go:build windows || linux\n", {"linux", "windows"}),
        ("a.go", "// +build linux,amd64 darwin\n", {"linux", "macos"}),
        ("a.go", "// +build unix\n// +build !darwin\nos.Chmod()", {"linux"}),
        ("a.go", "//go:build linux\n// +build windows\nos.Chmod()", {"linux"}),
        ("a_windows.go", "//go:build linux\nos.Chmod()", set()),
        ("a_linux.go", "runtime.GOOS", {"linux"}),
        ("a.go", "//go:build amd64\n", set()),
        ("a.go", "//go:build amd64\nruntime.GOOS", {"linux", "macos", "windows"}),
    ],
)
def test_source_signals(
    tmp_path: Path, filename: str, text: str, expected: set[str]
) -> None:
    path = tmp_path / filename
    path.write_text(text, encoding="utf-8")
    assert checker.implied_oses(path) == expected


@pytest.mark.parametrize("expression", ["42", "linux == windows", "linux()"])
def test_unsupported_build_constraint(expression: str) -> None:
    with pytest.raises(ValueError, match=r"^unsupported Go build constraint$"):
        checker.possibilities(ast.parse(expression, mode="eval").body, "linux")


def write(root: Path, relative: str, text: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


@pytest.mark.parametrize("macro", ["gomutants_test", "mutmut_test"])
@pytest.mark.parametrize(
    "attribute",
    ["", ", mutation_oses = None", ", mutation_oses = ['linux', 'macos', 'windows']"],
)
def test_unrestricted_passes(tmp_path: Path, macro: str, attribute: str) -> None:
    write(tmp_path, "BUILD.bazel", f'{macro}(name = "gate"{attribute})')
    write(tmp_path, "a.py", "sys.platform")
    write(tmp_path, "a.go", "runtime.GOOS")
    assert checker.check(tmp_path) == []


@pytest.mark.parametrize(
    ("macro", "suffix", "signal"),
    [("gomutants_test", "go", "runtime.GOOS"), ("mutmut_test", "py", "sys.platform")],
)
def test_narrow_list_reports_every_missing_os(
    tmp_path: Path, macro: str, suffix: str, signal: str
) -> None:
    write(tmp_path, "BUILD", f'{macro}(name = "gate", mutation_oses = ["linux"])')
    write(tmp_path, f"nested/a.{suffix}", signal)
    assert checker.check(tmp_path) == ["BUILD:1: mutation_oses missing macos, windows"]


@pytest.mark.parametrize(
    "attribute", ['"linux"', '["darwin"]', "1", "MISSING", "select({})", "[[]]"]
)
def test_unreadable_or_invalid_restriction_fails(
    tmp_path: Path, attribute: str
) -> None:
    write(tmp_path, "BUILD", f"mutmut_test(mutation_oses = {attribute})")
    assert checker.check(tmp_path) == [
        "BUILD:1: mutation_oses must be a literal list of linux, macos, windows or None"
    ]


def test_constants_empty_list_and_language_separation(tmp_path: Path) -> None:
    write(tmp_path, "BUILD", 'OSES = []\nmutmut_test(name="gate", mutation_oses=OSES)')
    write(tmp_path, "a.go", "runtime.GOOS")
    assert checker.check(tmp_path) == []
    write(tmp_path, "a.py", "sys.platform")
    assert checker.check(tmp_path) == [
        "BUILD:2: mutation_oses missing linux, macos, windows"
    ]


def test_multiple_macros_local_labels_and_external_package(tmp_path: Path) -> None:
    write(
        tmp_path,
        "gates/BUILD.bazel",
        'load("rules", "mutmut_test")\n'
        'mutmut_test(name="first", srcs=[":local", "@external//:repo_files", '
        '"//lib:unit"], mutation_oses=["linux"])\n'
        'mutmut_test(mutation_oses=["windows"])\n'
        "other_rule(mutation_oses=[])\nobj.method(mutation_oses=[])",
    )
    write(tmp_path, "lib/a.py", "pathlib.WindowsPath('C:/')")
    write(tmp_path, "other/a.py", "sys.platform")
    assert checker.check(tmp_path) == [
        "gates/BUILD.bazel:2: mutation_oses missing windows"
    ]


def test_go_test_labels_are_scanned(tmp_path: Path) -> None:
    write(
        tmp_path,
        "gates/BUILD",
        'gomutants_test(tests=["//lib:unit"], mutation_oses=["linux"])',
    )
    write(tmp_path, "lib/a_darwin.go", "")
    assert checker.check(tmp_path) == ["gates/BUILD:1: mutation_oses missing macos"]


def test_fixture_trees_are_not_repository_packages(tmp_path: Path) -> None:
    write(tmp_path, "testdata/tree/BUILD", "mutmut_test(mutation_oses=[])")
    write(tmp_path, "testdata/tree/a.py", "sys.platform")
    write(tmp_path, "BUILD", "mutmut_test(mutation_oses=[])")
    assert checker.check(tmp_path) == []


def test_main_success_and_defaults(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(sys, "argv", ["check_mutation_oses.py"])
    assert checker.main() == 0
    assert (
        capsys.readouterr().out
        == "OK: mutation OS lists cover platform-specific code\n"
    )


def test_main_failure(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    write(tmp_path, "BUILD", "mutmut_test(mutation_oses=[])")
    write(tmp_path, "a.py", "sys.platform")
    assert checker.main([str(tmp_path)]) == 1
    assert (
        capsys.readouterr().out
        == "BUILD:1: mutation_oses missing linux, macos, windows\n"
    )


def test_main_help(capsys: pytest.CaptureFixture[str]) -> None:
    with pytest.raises(SystemExit) as caught:
        checker.main(["--help"])
    assert caught.value.code == 0
    assert " Check mutation OS lists against source code. " in (
        " " + " ".join(capsys.readouterr().out.split()) + " "
    )


def test_unknown_tags_can_be_false_and_language_words_are_not_signals(
    tmp_path: Path,
) -> None:
    path = tmp_path / "a.go"
    path.write_text("//go:build !amd64 && windows\n", encoding="utf-8")
    assert checker.implied_oses(path) == {"windows"}
    path.write_text("var windows = 1", encoding="utf-8")
    assert checker.implied_oses(path) == set()
    path = tmp_path / "a.py"
    path.write_text('"""\n//go:build linux\n"""\nsys.platform', encoding="utf-8")
    assert checker.implied_oses(path) == {"linux", "macos", "windows"}


def test_unset_none_and_invalid_calls_do_not_stop_other_calls(tmp_path: Path) -> None:
    write(
        tmp_path,
        "BUILD",
        "mutmut_test()\nmutmut_test(mutation_oses=None)\n"
        "mutmut_test(mutation_oses=MISSING)\nmutmut_test(mutation_oses=[])",
    )
    write(tmp_path, "a.py", "sys.platform")
    assert checker.check(tmp_path) == [
        (
            "BUILD:3: mutation_oses must be a literal list of "
            "linux, macos, windows or None"
        ),
        "BUILD:4: mutation_oses missing linux, macos, windows",
    ]


def test_source_scope_includes_only_local_absolute_labels(tmp_path: Path) -> None:
    tree = ast.parse(
        'mutmut_test(srcs=glob(["*.py"]) + '
        '[":local", "@external//:unit", "//lib:unit"])',
        mode="eval",
    )
    assert isinstance(tree.body, ast.Call)
    assert checker.source_directories(tree.body, tmp_path / "gate", tmp_path) == {
        tmp_path / "gate",
        tmp_path / "lib",
    }
