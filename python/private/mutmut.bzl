# SPDX-License-Identifier: Apache-2.0
# Copyright Tony Burns

"""Mutation testing with mutmut: a cached report action and its gate."""

load("@tbhb_rules//quality:defs.bzl", "MutationReportInfo", "mutation_gate_test")
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
    launcher = ctx.attr.runner[DefaultInfo].files_to_run
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = script,
        substitutions = {
            "@@LAUNCHER@@": launcher.executable.path,
            "@@LOG@@": log.path,
            "@@MANIFEST@@": manifest.path,
            "@@REPORT@@": report.path,
        },
        is_executable = True,
    )
    ctx.actions.run(
        executable = script,
        inputs = depset([manifest], transitive = [depset(files)]),
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
    attrs = {
        "cpus": attr.int(doc = "CPUs to reserve for the action (`cpu:N`), 0 for Bazel's default."),
        "runner": attr.label(
            mandatory = True,
            executable = True,
            cfg = "exec",
            doc = "The python_tool that runs mutmut_report.py.",
        ),
        "srcs": attr.label_list(allow_files = True, mandatory = True, doc = "Files to copy, usually a `repo_files` target."),
        "_template": attr.label(default = ":mutmut.sh.tpl", allow_single_file = True),
    },
)

def mutmut_test(name, srcs, chdir = "", python_env = DEFAULT_ENV, cpus = 0, **kwargs):
    """Mutation-tests the tree with mutmut and fails unless every mutant was killed.

    Creates `<name>.report` (the cached mutmut run) and `<name>`, a
    `mutation_gate_test` over it: any survivor, timeout, suspicious or
    untested mutant, crash, interruption or unchecked mutant fails, and so
    does a run that mutated nothing. Mark an equivalent mutant with
    `# pragma: no mutate` and a reason.

    Args:
        name: Target name.
        srcs: Files to copy, usually a `repo_files` target.
        chdir: Directory, relative to the tree root, to run mutmut from; its
            pyproject.toml holds `[tool.mutmut]`. mutmut maps source files to
            module names only for a src layout or the run directory itself.
        python_env: The Python environment, which must provide mutmut and pytest.
        cpus: CPUs to reserve for the mutmut action.
        **kwargs: Passed to the gate test.
    """
    python_tool(
        name = name + ".runner",
        main = Label(":mutmut_report.py"),
        chdir = chdir,
        python_env = python_env,
        tags = ["manual"],
        visibility = ["//visibility:private"],
    )
    mutmut_report(
        name = name + ".report",
        srcs = srcs,
        runner = ":{}.runner".format(name),
        cpus = cpus,
        tags = kwargs.get("tags", []),
        visibility = ["//visibility:private"],
    )
    mutation_gate_test(
        name = name,
        reports = [":{}.report".format(name)],
        **kwargs
    )
