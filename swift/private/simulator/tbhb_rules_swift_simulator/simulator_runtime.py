# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

from typing import TypedDict


class DeviceType(TypedDict):
    name: str


class Runtime(TypedDict):
    identifier: str
    platform: str
    version: str
    isAvailable: bool
    supportedDeviceTypes: list[DeviceType]


class RuntimeList(TypedDict):
    runtimes: list[Runtime]


def select_runtime(runtimes: RuntimeList, device_type: str, os_version: str) -> str:
    """Select an available iOS runtime that supports both version and device."""
    for runtime in runtimes["runtimes"]:
        if (
            runtime["platform"] == "iOS"
            and runtime["isAvailable"]
            and runtime["version"] == os_version
            and any(
                device["name"] == device_type
                for device in runtime.get("supportedDeviceTypes", [])
            )
        ):
            return runtime["identifier"]
    message = (
        f"No available iOS {os_version} runtime supports device type {device_type!r}"
    )
    raise RuntimeError(message)
