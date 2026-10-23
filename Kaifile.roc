app [kaifile] {
	pf: platform "https://github.com/thebrandonlucas/kai/releases/download/v0.0.9/EenHNXeRqmvf2kHJLLbjroXeLwbQxyH5fbVQVgD3DXg4.tar.zst",
	std: "https://github.com/thebrandonlucas/kai/releases/download/v0.0.9/std-DiShoF1FRWjQe7BmRnSTmqG44WgHUGuMMTMgBoaBqemq.tar.zst",
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
	Task("test", [Use("dev"), Run(["roc", "test", "package/main.roc"])]),

	Task("check", [Use("dev"), Run(["roc", "check", "cli/main.roc"])]),

	Task("format", [Use("dev"), Run(["roc", "fmt", "package", "cli"])]),
])
