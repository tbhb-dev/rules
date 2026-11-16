# Agent instructions

Before choosing a model for a subagent or peer run, read models/README.md in tbhb-dev/wiki (<https://github.com/tbhb-dev/wiki/blob/main/models/README.md>).

## Tests that run a subprocess

Windows legs run only on pushes to main. A failure there shows only after the merge, on main. Give every new test that runs a subprocess the Windows exclusion in the same pull request, unless the test targets Windows:

```starlark
target_compatible_with = select({
    "@platforms//os:windows": ["@platforms//:incompatible"],
    "//conditions:default": [],
}),
```

Add a tech-debt comment on the line before it, and a tracker row. A reviewer checks for the exclusion on any new test that shells out, and reports a missing one as blocking.
