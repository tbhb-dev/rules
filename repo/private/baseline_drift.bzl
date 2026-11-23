# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""The consumer test for bytes-mode baseline drift."""

load("@rules_shell//shell:sh_test.bzl", "sh_test")

visibility("//repo/...")

_TOOL = Label("//repo/baseline:drift_tool")
_BASELINE = Label("//repo/baseline:repo_files")
_RUNNER = Label(":baseline_drift.sh")

def baseline_drift_test(name, srcs, mode = "warn", **kwargs):
    """Compares a consumer's bytes-mode files with the pinned baseline.

    Args:
        name: Test target name.
        srcs: Consumer root files, usually [":repo_files"], including .tbhb-repo.toml.
        mode: "warn" reports drift and passes. "required" fails on drift.
        **kwargs: Additional sh_test attributes.
    """
    if mode not in ("warn", "required"):
        fail("baseline_drift_test mode must be warn or required")
    sh_test(
        name = name,
        srcs = [_RUNNER],
        args = ["$(rootpath {})".format(_TOOL), "check", "--mode", mode, "."],
        data = [_TOOL, _BASELINE] + srcs,
        # Enable the subprocess test on Windows after verifying runfiles (tbhb-dev/rules#344).
        target_compatible_with = select({
            Label("@platforms//os:windows"): [Label("@platforms//:incompatible")],
            "//conditions:default": [],
        }),
        **kwargs
    )
