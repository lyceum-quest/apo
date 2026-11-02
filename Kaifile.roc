app [kaifile] {
	pf: platform "https://github.com/thebrandonlucas/kai/releases/download/v0.0.10/9jXNkEdEWZ3cyQqHMLyTenLr4Xj5nEJT48UwnU8AxPCp.tar.zst",
	std: "https://github.com/thebrandonlucas/kai/releases/download/v0.0.10/std-CJKhhQ3UzajxpUqUKcpv2cwHGJpXQ8qPRiHKL5prqK2y.tar.zst",
}

import std.Std

kaifile = Std.kaifile([
	Name("apo"),
	Overlay("roc", "github:roc-lang/roc-overlay"),
	Environment(
		"dev",
		[
			Tools([
				"coreutils",
				"diffutils",
				"git",
				"rocpkgs.nightly-2026-10-21-5349569",
			]),
			Overlays(["roc"]),
		],
	),
	Shell("default", [Use("dev")]),

	# Builds ./apo.
	Task("build", [Use("dev"), Run(["roc", "build", "cli/main.roc", "--output=apo"])]),

	# The package's expects: every module's checks, without models or network.
	# --no-cache works around Roc returning wrong results after `kai run build` compiled the same modules. Remove it when
	# https://github.com/thebrandonlucas/roc-issues/tree/master/bugs/BUG-020-test-after-build-wrong-constant passes.
	Task("test", [Use("dev"), Run(["roc", "test", "package/main.roc", "--no-cache"])]),

	# Builds the deterministic stand-in model the end-to-end tests run through the command protocol.
	Task("build-echo-model", [Use("dev"), Run(["roc", "build", "tests/echo-model.roc", "--output=tests/echo-model"])]),

	# A whole run with the stand-in model, from a fresh store, compared with the committed expected outputs.
	Task("e2e-clean", [Use("dev"), Run(["rm", "-rf", "tests/echo/runs"])]),

	Task("e2e-run", [Use("dev"), Run(["./apo", "run", "tests/echo/experiment.json", "--only", "echo"])]),

	Task("e2e-compare", [Use("dev"), Run(["diff", "-r", "tests/echo/expected", "tests/echo/runs/echo/echo-0a8b18d9ac/output"])]),

	Workflow("e2e", [RunTask("build", []), RunTask("build-echo-model", []), RunTask("e2e-clean", []), RunTask("e2e-run", []), RunTask("e2e-compare", [])]),

	Task("check", [Use("dev"), Run(["roc", "check", "cli/main.roc"])]),

	Task("format", [Use("dev"), Run(["roc", "fmt", "package", "cli"])]),
])
