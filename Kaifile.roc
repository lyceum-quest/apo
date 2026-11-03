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

	# A whole run with the stand-in model, from nothing, in two resumed parts, compared with the committed expected
	# outputs.
	Task("e2e-clean", [Use("dev"), Run(["rm", "-rf", "tests/echo/apo-output"])]),

	Task("e2e-run-first", [Use("dev"), Run(["./apo", "run", "--config", "tests/echo/config.json", "--count", "3"])]),

	Task("e2e-run-rest", [Use("dev"), Run(["./apo", "run", "--config", "tests/echo/config.json"])]),

	Task("e2e-compare", [Use("dev"), Run(["diff", "-r", "tests/echo/expected", "tests/echo/apo-output/crito/echo"])]),

	Workflow("e2e", [RunTask("build", []), RunTask("build-echo-model", []), RunTask("e2e-clean", []), RunTask("e2e-run-first", []), RunTask("e2e-run-rest", []), RunTask("e2e-compare", [])]),

	# Release binaries for Linux, statically linked so they run on any distribution. The macOS binary needs Apple's
	# libSystem to link, so .github/workflows/release.yml builds it on a Mac with this Kaifile's Roc.
	Task("dist-dir", [Use("dev"), Run(["mkdir", "-p", "dist"])]),

	Task("build-linux-x64", [Use("dev"), Run(["roc", "build", "cli/main.roc", "--target=x64musl", "--output=dist/apo-x86_64-linux"])]),

	Task("build-linux-arm64", [Use("dev"), Run(["roc", "build", "cli/main.roc", "--target=arm64musl", "--output=dist/apo-aarch64-linux"])]),

	Workflow("build-linux", [RunTask("dist-dir", []), RunTask("build-linux-x64", []), RunTask("build-linux-arm64", [])]),

	Task("check", [Use("dev"), Run(["roc", "check", "cli/main.roc"])]),

	Task("format", [Use("dev"), Run(["roc", "fmt", "package", "cli"])]),
])
