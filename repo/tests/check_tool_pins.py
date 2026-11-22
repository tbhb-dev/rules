# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns
# ruff: noqa: INP001 -- Standalone script, run by path.

"""Compare pins/tools.json with the pinned archives in pins/extensions.bzl.

Usage: check_tool_pins.py TOOLS_JSON EXTENSIONS_BZL
The extension's literal `http_archive` calls stay the source for Bazel and
Renovate. The JSON mirrors them for installers outside Bazel, so a bump that
moves one side without the other fails here. Failures are one line each.
"""

import argparse
import json
import re
import sys
from pathlib import Path

# Hub platform suffix in extensions.bzl to the platform key in tools.json.
PLATFORMS = {
    "macos_arm64": "darwin_arm64",
    "linux_x86_64": "linux_amd64",
    "linux_arm64": "linux_arm64",
    "windows_x86_64": "windows_amd64",
}

ARCHIVE = re.compile(
    r'name = "tbhb_rules_(?P<tool>[a-z_]+?)_'
    r'(?P<platform>macos_arm64|linux_x86_64|linux_arm64|windows_x86_64)",'
    r'.*?sha256 = "(?P<sha256>[0-9a-f]+)",'
    r'.*?url = "(?P<url>[^"]+)",',
    re.DOTALL,
)


def bzl_pins(text: str) -> dict[str, dict[str, dict[str, str]]]:
    pins: dict[str, dict[str, dict[str, str]]] = {}
    for match in ARCHIVE.finditer(text):
        platforms = pins.setdefault(match["tool"], {})
        platforms[PLATFORMS[match["platform"]]] = {
            "url": match["url"],
            "sha256": match["sha256"],
        }
    return pins


def check(tools_json: Path, extensions: Path) -> list[str]:
    data = json.loads(tools_json.read_text())
    pins = bzl_pins(extensions.read_text())
    errors = []
    for tool, entry in data.items():
        for platform, pin in entry["platforms"].items():
            bzl = pins.get(tool, {}).get(platform)
            if bzl != pin:
                errors.append(
                    f"{tools_json}: {tool} {platform} differs from {extensions}: "
                    f"{pin} vs {bzl}"
                )
            if f"v{entry['version']}" not in pin["url"]:
                errors.append(
                    f"{tools_json}: {tool} {platform} url does not carry "
                    f"version {entry['version']}"
                )
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("tools_json", type=Path)
    parser.add_argument("extensions", type=Path)
    args = parser.parse_args(argv)
    errors = check(args.tools_json, args.extensions)
    sys.stdout.write("".join(f"{error}\n" for error in errors))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
