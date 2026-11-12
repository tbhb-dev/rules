<!--
SPDX-License-Identifier: Apache-2.0
Copyright Tony Burns
-->

# Swift module

See the [Swift module reference](../docs/reference/swift.md) for build macros, pins, checks, and the smoke consumer.

The default `tbhb_ios_unit_test` runner selects an available iOS runtime that supports `device_type` and `os_version`. The module supplies the simulator tools in `private/simulator` and configures the default runner.

## Consuming the module

Bazel ignores a non-root module's `local_path_override`. A consumer must declare its own overrides for both `tbhb_rules` and `tbhb_rules_swift`. For a local checkout:

```starlark
bazel_dep(name = "tbhb_rules")
bazel_dep(name = "tbhb_rules_swift")

local_path_override(
    module_name = "tbhb_rules",
    path = "../rules",
)
local_path_override(
    module_name = "tbhb_rules_swift",
    path = "../rules/swift",
)
```
