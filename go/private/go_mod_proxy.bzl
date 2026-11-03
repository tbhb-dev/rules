# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""`go_mod_proxy`: a module proxy directory holding what a go.sum lists.

The repository is laid out as a GOPROXY (`<module>/@v/<version>.{mod,zip,info}`
and `<module>/@v/list`), downloaded from a real proxy at fetch time, so a
test can point the go command at it with `GOPROXY=file://...` and run with
no network. Nothing here is trusted: the go command checks every `.mod` and
`.zip` it reads against go.sum, which is the input under test.
"""

# Internal: consumers load //:extensions.bzl.
visibility(["//"])

def _escape(path):
    # Module paths and versions escape upper-case letters as "!" plus the
    # lower-case letter (golang.org/x/mod/module.EscapePath).
    out = ""
    for c in path.elems():
        out += "!" + c.lower() if c.isupper() else c
    return out

def _parse_go_sum(content):
    mods = {}
    zips = {}
    for line in content.splitlines():
        fields = line.split(" ")
        if len(fields) != 3:
            continue
        path, version = fields[0], fields[1]
        if version.endswith("/go.mod"):
            mods[(path, version[:-len("/go.mod")])] = True
        else:
            zips[(path, version)] = True
    return mods, zips

def _go_mod_proxy_repo_impl(rctx):
    mods, zips = _parse_go_sum(rctx.read(rctx.attr.go_sum))
    base = rctx.attr.proxy_url.rstrip("/")
    versions = {}
    for (path, version) in mods.keys() + zips.keys():
        versions.setdefault(path, {})[version] = True
    for path, vs in versions.items():
        prefix = "{}/@v/".format(_escape(path))
        rctx.file(prefix + "list", "".join([v + "\n" for v in sorted(vs.keys())]))
        for version in vs.keys():
            name = prefix + _escape(version)
            rctx.file(name + ".info", json.encode({"Version": version}) + "\n")
            if (path, version) in mods:
                rctx.download(url = "{}/{}.mod".format(base, name), output = name + ".mod")
            if (path, version) in zips:
                rctx.download(url = "{}/{}.zip".format(base, name), output = name + ".zip")
    rctx.file("go_mod_proxy.root", "")
    rctx.file("BUILD.bazel", """\
filegroup(
    name = "proxy",
    srcs = ["go_mod_proxy.root"] + glob(["**/@v/*"]),
    visibility = ["//visibility:public"],
)
""")

go_mod_proxy_repo = repository_rule(
    implementation = _go_mod_proxy_repo_impl,
    doc = "A GOPROXY directory with the modules a go.sum lists; target `:proxy`.",
    attrs = {
        "go_sum": attr.label(mandatory = True, allow_single_file = True),
        "proxy_url": attr.string(default = "https://proxy.golang.org"),
    },
)

_from_file = tag_class(
    doc = "A proxy repository for one go.sum.",
    attrs = {
        "name": attr.string(mandatory = True, doc = "Repository name, for use_repo."),
        "go_sum": attr.label(mandatory = True, doc = "The go.sum whose modules to fetch."),
        "proxy_url": attr.string(default = "https://proxy.golang.org", doc = "The proxy to fetch from."),
    },
)

def _go_mod_proxy_impl(mctx):
    for mod in mctx.modules:
        for tag in mod.tags.from_file:
            go_mod_proxy_repo(name = tag.name, go_sum = tag.go_sum, proxy_url = tag.proxy_url)

go_mod_proxy = module_extension(
    implementation = _go_mod_proxy_impl,
    doc = """Module proxies for go_mod_tidy_test, one per go.sum.

```starlark
go_mod_proxy = use_extension("@tbhb_rules_go//:extensions.bzl", "go_mod_proxy")
go_mod_proxy.from_file(name = "go_mod_proxy", go_sum = "//:go.sum")
use_repo(go_mod_proxy, "go_mod_proxy")
```""",
    tag_classes = {"from_file": _from_file},
)
