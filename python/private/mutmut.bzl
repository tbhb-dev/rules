# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Mutation testing with mutmut: a cached report action and its gate."""

load(
    "@tbhb_rules//quality:defs.bzl",
    "MUTATION_CHANGES_ATTRS",
    "MutationReportInfo",
    "mutation_changes_slice",
    "mutation_gate_test",
)
load(":tool.bzl", "DEFAULT_ENV", "python_tool")

# Internal: consumers load //:defs.bzl.
visibility("//...")

def _tree_path(file):
    if file.owner.repo_name != "":
        fail("{} is from repository @{}; only files of the main repository can be mutated".format(
            file.short_path,
            file.owner.repo_name,
        ))
    return file.short_path

def _mutmut_report_impl(ctx):
    files = depset(ctx.files.srcs).to_list()
    if not files:
        fail("srcs is empty: there is nothing to mutate")
    manifest = ctx.actions.declare_file(ctx.label.name + ".manifest")
    ctx.actions.write(
        output = manifest,
        content = "".join(["{}\t{}\n".format(f.path, _tree_path(f)) for f in files]),
    )
    report = ctx.actions.declare_file(ctx.label.name + ".report")
    log = ctx.actions.declare_file(ctx.label.name + ".log")
    script = ctx.actions.declare_file(ctx.label.name + ".sh")

    # Only the unit's slice of the change set is an input, so a change
    # elsewhere leaves this action cached.
    changes = mutation_changes_slice(ctx, files)
    launcher = ctx.attr.runner[DefaultInfo].files_to_run
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = script,
        substitutions = {
            "@@CHANGES@@": changes.path if changes else "",
            "@@CHDIR@@": ctx.attr.chdir,
            "@@LAUNCHER@@": launcher.executable.path,
            "@@LOG@@": log.path,
            "@@MANIFEST@@": manifest.path,
            "@@REPORT@@": report.path,
        },
        is_executable = True,
    )
    ctx.actions.run(
        executable = script,
        inputs = depset([manifest] + ([changes] if changes else []), transitive = [depset(files)]),
        outputs = [report, log],
        tools = [launcher],
        mnemonic = "Mutmut",
        progress_message = "Mutation-testing %{label} with mutmut",
        # mutmut forks a worker per CPU and times each mutant against the
        # clean run; running alone keeps those timings honest.
        execution_requirements = {"cpu:" + str(ctx.attr.cpus): ""} if ctx.attr.cpus else {},
    )
    return [
        DefaultInfo(files = depset([report, log])),
        MutationReportInfo(reports = depset([report])),
    ]

mutmut_report = rule(
    implementation = _mutmut_report_impl,
    doc = """Runs mutmut over a copy of `srcs` in a cached action.

The copy keeps the repository layout, and mutmut runs from the launcher's
`chdir`, so the `[tool.mutmut]` table of that directory's pyproject.toml
applies and tests that find data by walking up still do. The report lands
in `<name>.report` (MutationReportInfo) and mutmut's output in
`<name>.log`. The action reruns only when an input changes.""",
    attrs = MUTATION_CHANGES_ATTRS | {
        "chdir": attr.string(doc = "The runner's run directory, relative to the tree root, for mapping the change set."),
        "cpus": attr.int(doc = "CPUs to reserve for the action (`cpu:N`), 0 for Bazel's default."),
        "runner": attr.label(
            mandatory = True,
            executable = True,
            cfg = "exec",
            doc = "The python_tool that runs mutmut_report.py.",
        ),
        "srcs": attr.label_list(allow_files = True, mandatory = True, doc = "Files to copy: python_library units (their deps' files come along) plus config, or a `repo_files` target."),
        "_template": attr.label(default = ":mutmut.sh.tpl", allow_single_file = True),
    },
)

def mutmut_test(name, srcs, chdir = "", python_env = DEFAULT_ENV, cpus = 0, changes = None, **kwargs):
    """Mutation-tests the tree with mutmut and fails unless every mutant was killed.

    Creates `<name>.report` (the cached mutmut run) and `<name>`, a
    `mutation_gate_test` over it: any survivor, timeout, suspicious or
    untested mutant, crash, interruption or unchecked mutant fails, and so
    does a run that mutated nothing. Mark an equivalent mutant with
    `# pragma: no mutate` and a reason.

    Incremental: the report is a cached action over exactly `srcs`. Give it
    a unit (a python_library, whose deps' files come along) and the config
    it needs rather than the whole tree: a change then reruns this unit's
    report, and every unit whose deps include the changed one, and nothing
    else. Bazel's dependency graph decides; mutmut's own dependency tracking
    is not relied on.

    Diff-aware: with a change set (`--@tbhb_rules//quality:changes`, or
    `changes` here), the action gets only this unit's slice of it, and only
    the mutants of the changed functions run; the report says `scope=diff`.
    An empty slice runs nothing and passes. The run is full instead when no
    change set is set (the default), or the slice touches a test file or
    conftest.py, a non-Python file (config, data, the lock), a module-level
    statement, an added or deleted file, or any file outside the run
    directory (a dependency's source or the root config): those can change
    any verdict. A diff pass never stands for a full run (`require_scope`);
    mutants of unchanged functions are checked by full runs.

    Under a cgroup CPU quota below the host's CPU count, the driver runs
    mutmut with `--max-children` set to the quota, read at run time, so the
    quota never enters the action's cache key.

    mutmut does not run on Windows (it points Windows users to WSL), so the
    targets are incompatible there: `bazel test //...` skips them.

    Args:
        name: Target name.
        srcs: Files to copy, usually a `repo_files` target.
        chdir: Directory, relative to the tree root, to run mutmut from; its
            pyproject.toml holds `[tool.mutmut]`. mutmut maps source files to
            module names only for a src layout or the run directory itself.
        python_env: The Python environment, which must provide mutmut and pytest.
        cpus: CPUs to reserve for the mutmut action.
        changes: A change set file overriding quality's `changes` flag, for
            fixtures and proofs; it must have mutation_changes' layout.
        **kwargs: Passed to the gate test.
    """
    not_windows = select({
        Label("@platforms//os:windows"): [Label("@platforms//:incompatible")],
        "//conditions:default": [],
    })
    compatible = kwargs.pop("target_compatible_with", []) + not_windows
    python_tool(
        name = name + ".runner",
        main = Label(":mutmut_report.py"),
        chdir = chdir,
        python_env = python_env,
        tags = ["manual"],
        target_compatible_with = compatible,
        visibility = ["//visibility:private"],
    )
    mutmut_report(
        name = name + ".report",
        srcs = srcs,
        runner = ":{}.runner".format(name),
        chdir = chdir,
        changes = changes,
        cpus = cpus,
        tags = kwargs.get("tags", []),
        target_compatible_with = compatible,
        visibility = ["//visibility:private"],
    )
    mutation_gate_test(
        name = name,
        reports = [":{}.report".format(name)],
        target_compatible_with = compatible,
        **kwargs
    )
