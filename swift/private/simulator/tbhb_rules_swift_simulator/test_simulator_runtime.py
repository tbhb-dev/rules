# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

# Use stdlib unittest so the smoke needs no third-party test packages.

import json
import re
import unittest
from pathlib import Path

from tbhb_rules_swift_simulator.simulator_runtime import RuntimeList, select_runtime


class SimulatorRuntimeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.runtimes: RuntimeList = json.loads(
            Path(__file__).with_name("testdata").joinpath("runtimes.json").read_text()
        )

    def test_device_specific_runtime_precedes_general_runtime(self) -> None:
        assert (
            select_runtime(self.runtimes, "iPhone 17", "27.2")
            == "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
        )

    def test_no_runtime_supports_device(self) -> None:
        try:
            select_runtime(self.runtimes, "iPhone 16", "27.2")
        except RuntimeError as error:
            error_message = str(error)
        else:
            message = "expected RuntimeError"
            raise AssertionError(message)
        assert re.search(
            "No available iOS 27.2 runtime supports device type 'iPhone 16'",
            error_message,
        )

    def test_unavailable_runtime_is_rejected(self) -> None:
        self.runtimes["runtimes"][1]["isAvailable"] = False
        try:
            select_runtime(self.runtimes, "iPhone 17", "27.2")
        except RuntimeError as error:
            error_message = str(error)
        else:
            message = "expected RuntimeError"
            raise AssertionError(message)
        assert re.search("iPhone 17", error_message)

    def test_wrong_platform_is_rejected(self) -> None:
        self.runtimes["runtimes"][1]["platform"] = "tvOS"
        try:
            select_runtime(self.runtimes, "iPhone 17", "27.2")
        except RuntimeError as error:
            error_message = str(error)
        else:
            message = "expected RuntimeError"
            raise AssertionError(message)
        assert re.search("iPhone 17", error_message)

    def test_wrong_version_is_rejected(self) -> None:
        try:
            select_runtime(self.runtimes, "iPhone 17", "27.1")
        except RuntimeError as error:
            error_message = str(error)
        else:
            message = "expected RuntimeError"
            raise AssertionError(message)
        assert re.search("iOS 27.1", error_message)

    def test_general_runtime_precedes_device_specific_runtime(self) -> None:
        self.runtimes["runtimes"].reverse()
        assert (
            select_runtime(self.runtimes, "iPhone 17", "27.2")
            == "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
        )

    def test_device_specific_runtime_can_support_requested_device(self) -> None:
        assert (
            select_runtime(self.runtimes, "iPhone Duo", "27.2")
            == "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4"
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
