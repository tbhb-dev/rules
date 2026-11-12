# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Adapt the pinned rules_apple creator to device-specific iOS runtimes."""

import json
import os
import sys

from apple.testing.default_runner.simulator_creator import (
    Namespace,
)
from apple.testing.default_runner.simulator_creator import (
    _build_parser as build_parser,
)
from apple.testing.default_runner.simulator_creator import (
    _create_and_boot_simulator as create_and_boot_simulator,
)
from apple.testing.default_runner.simulator_creator import (
    _default_device_name as default_device_name,
)
from apple.testing.default_runner.simulator_creator import (
    _selected_simulator_runtime as selected_simulator_runtime,
)
from apple.testing.default_runner.simulator_creator import (
    _simctl as simctl,
)

from tools.simulator_runtime import select_runtime


def main() -> None:
    # Keep upstream's CLI, environment, naming, reuse and bootstatus behavior.
    # Only runtime selection changes for the smoke's explicit OS version.
    parser = build_parser()
    args = parser.parse_args(namespace=Namespace())
    device_type = args.device_type or os.getenv("SIMULATOR_DEVICE_TYPE")
    if not device_type:
        parser.error("Device type is required (SIMULATOR_DEVICE_TYPE or --device-type)")
    os_version = args.os_version or os.getenv("SIMULATOR_OS_VERSION")
    sdk_version = args.sdk_version or os.getenv("SIMULATOR_SDK_VERSION")
    if not os_version:
        # Preserve upstream's SDK build mapping and patch-version fallback
        # when the runner supplies only SIMULATOR_SDK_VERSION.
        os_version = selected_simulator_runtime(None, sdk_version).version
    runtime_id = select_runtime(
        json.loads(simctl(["list", "runtimes", "-j"])), device_type, os_version
    )
    reuse_simulator = (
        args.reuse_simulator
        if args.reuse_simulator is not None
        else os.getenv("SIMULATOR_REUSE_SIMULATOR", "1").lower() in ("1", "true")
    )
    device_name = args.name or default_device_name(device_type, os_version)
    sys.stderr.write(f"Selected simulator runtime {runtime_id}\n")
    simulator_id = create_and_boot_simulator(
        device_name, device_type, runtime_id, reuse_simulator=reuse_simulator
    )
    # The runner captures stdout as the UDID; diagnostics belong on stderr.
    sys.stdout.write(f"{simulator_id.strip()}\n")


if __name__ == "__main__":
    main()
