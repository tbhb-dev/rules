# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Use stdlib unittest so the smoke needs no third-party test packages.

import contextlib
import io
import os
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from private.simulator import create_simulator


class CreateSimulatorTest(unittest.TestCase):
    def test_runner_environment_and_stdout(self) -> None:
        runtimes = Path(__file__).with_name("testdata").joinpath("runtimes.json")
        for reuse_value, expected in [("1", True), ("true", True), ("", False)]:
            with (
                self.subTest(reuse_value=reuse_value),
                patch.dict(
                    os.environ,
                    {
                        "SIMULATOR_DEVICE_TYPE": "iPhone 17",
                        "SIMULATOR_OS_VERSION": "27.2",
                        "SIMULATOR_SDK_VERSION": "27.2",
                        "SIMULATOR_REUSE_SIMULATOR": reuse_value,
                    },
                    clear=True,
                ),
                patch("sys.argv", ["create_simulator"]),
                patch.object(
                    create_simulator, "simctl", return_value=runtimes.read_text()
                ) as simctl,
                patch.object(
                    create_simulator, "create_and_boot_simulator", return_value="UDID\n"
                ) as create_and_boot,
                contextlib.redirect_stdout(io.StringIO()) as stdout,
                contextlib.redirect_stderr(io.StringIO()) as stderr,
            ):
                create_simulator.main()
                simctl.assert_called_once_with(["list", "runtimes", "-j"])
                create_and_boot.assert_called_once_with(
                    "BAZEL_TEST_iPhone 17_27.2",
                    "iPhone 17",
                    "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                    reuse_simulator=expected,
                )
                assert stdout.getvalue() == "UDID\n"
                assert "Selected simulator runtime" in stderr.getvalue()

    def test_sdk_fallback_and_cli_overrides(self) -> None:
        runtimes = Path(__file__).with_name("testdata").joinpath("runtimes.json")
        with (
            patch.dict(os.environ, {"SIMULATOR_SDK_VERSION": "27.2"}, clear=True),
            patch(
                "sys.argv",
                [
                    "create_simulator",
                    "--device-type",
                    "iPhone 17",
                    "--name",
                    "custom simulator",
                    "--no-reuse-simulator",
                ],
            ),
            patch.object(
                create_simulator,
                "selected_simulator_runtime",
                return_value=SimpleNamespace(version="27.2"),
            ) as sdk_runtime,
            patch.object(create_simulator, "simctl", return_value=runtimes.read_text()),
            patch.object(
                create_simulator, "create_and_boot_simulator", return_value="UDID"
            ) as create_and_boot,
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            create_simulator.main()
            sdk_runtime.assert_called_once_with(None, "27.2")
            create_and_boot.assert_called_once_with(
                "custom simulator",
                "iPhone 17",
                "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                reuse_simulator=False,
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
