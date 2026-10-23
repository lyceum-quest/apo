# apo: run language models over CoNLL-U, validate the output, and measure it.
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	apo: "../package/main.roc",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}

import pf.OsStr
import pf.Path
import pf.Stderr
import pf.Stdout
import apo.Gold
import apo.JsonValue
import apo.Validate

import Archive
import Compare
import Evaluate
import Execute
import Io
import Load

import "../VERSION" as raw_version : Str

version = raw_version.trim()

usage =
	\\usage: apo <command> [options]
	\\
	\\commands:
	\\  validate <file.conllu>... [--profile <profile.json>] [--json]   check CoNLL-U files
	\\  plan <experiment.json> [--only <label>]                        the calls a run would make, and their cost
	\\  run <experiment.json> [--paid] [--only <label>]                run an experiment; resumes from its store
	\\  gold fetch <gold.json>                                         download and check a gold set
	\\  eval <run-dir>... --gold <gold.json> [--json]                  score runs against a gold set
	\\  compare <run-dir>... --judge <judge.json> --out <dir>          rank runs by pairwise preference (see --help)
	\\  export <run-dir> <work-dir>                                    write a run as an archive work folder
	\\  adopt <work-dir> [--runs <dir>]                                wrap a pre-apo work folder as a run
	\\  seed <experiment.json> --from <work-dir> [--only <label>]     fill a run's store from a pre-apo work folder
	\\
	\\Run `apo <command> --help` for a command's options.

main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	shown = args.map(OsStr.display)
	match run!(shown) {
		Ok({}) => Ok({})
		Err(Usage(message)) => {
			_ = Stderr.line!(message)
			Err(Exit(2))
		}
		Err(Failed(message)) => {
			_ = Stderr.line!("apo: ${message}")
			Err(Exit(1))
		}
		Err(Invalid) => Err(Exit(1))
		Err(other) => {
			_ = Stderr.line!("apo: ${Str.inspect(other)}")
			Err(Exit(1))
		}
	}
}

run! = |shown| match shown {
	["validate", .. as rest] => validate!(rest)
	["plan", .. as rest] => plan!(rest)
	["run", .. as rest] => run_experiment!(rest)
	["gold", .. as rest] => gold!(rest)
	["eval", .. as rest] => eval!(rest)
	["compare", .. as rest] => compare!(rest)
	["export", .. as rest] => export!(rest)
	["adopt", .. as rest] => adopt!(rest)
	["seed", .. as rest] => seed!(rest)
	["--version"] => Stdout.line!(version)
	["--help"] | ["-h"] | ["help"] | [] => Stdout.line!(usage)
	[command, ..] => Err(Usage("apo: unknown command ${command}\n\n${usage}"))
}

## Options as (`--name`, value) pairs and the remaining positional arguments; `flags` take no value.
options : List(Str), List(Str) -> Try({ named : List((Str, Str)), positional : List(Str) }, [Usage(Str)])
options = |words, flags| {
	var $named = []
	var $positional = []
	var $pending = Err(None)
	for word in words {
		match $pending {
			Ok(name) => {
				$named = $named.append((name, word))
				$pending = Err(None)
			}
			Err(_) => if word.starts_with("--") {
				if flags.contains(word) {
					$named = $named.append((word, ""))
				} else {
					$pending = Ok(word)
				}
			} else {
				$positional = $positional.append(word)
			}
		}
	}
	match $pending {
		Ok(name) => Err(Usage("apo: ${name} needs a value"))
		Err(_) => Ok({ named: $named, positional: $positional })
	}
}

option : { named : List((Str, Str)), positional : List(Str) }, Str -> Try(Str, [Missing])
option = |parsed, name| match parsed.named.keep_if(|(n, _)| n == name) {
	[(_, v), ..] => Ok(v)
	[] => Err(Missing)
}

has_flag = |parsed, name| parsed.named.any(|(n, _)| n == name)

read! = |path| Path.read_utf8!(Path.unix(path)).map_err(|_| Failed("cannot read ${path}"))

json_file! = |path| JsonValue.decode(read!(path)?).map_err(|message| Failed("${path}: ${message}"))

validate! = |words| {
	parsed = options(words, ["--json", "--help"])?
	if has_flag(parsed, "--help") or parsed.positional.is_empty() {
		return Stdout.line!("usage: apo validate [--profile <profile.json>] [--json] <file.conllu>...\n\nChecks CoNLL-U format, and a profile's rules if given. Exits 1 if any file has problems.")
	}
	rules = match option(parsed, "--profile") {
		Ok(path) => Validate.profile(json_file!(path)?).map_err(|message| Failed("${path}: ${message}"))?
		Err(_) => Validate.no_profile
	}
	var $total = 0
	for file in parsed.positional {
		problems = Validate.check(read!(file)?, rules)
		for p in problems {
			_ = if has_flag(parsed, "--json") {
				Stdout.line!(JsonValue.encode(JsonValue.object([("file", JsonValue.str(file)), ("line", JsonValue.u64(p.line)), ("code", JsonValue.str(p.code)), ("message", JsonValue.str(p.message))])))
			} else {
				Stdout.line!("${file}:${p.line.to_str()}: ${p.code}: ${p.message}")
			}
		}
		$total = $total + problems.len()
	}
	if $total == 0 {
		Stderr.line!("${parsed.positional.len().to_str()} file(s) valid${if rules.name == "" "" else " under ${rules.name}"}").map_err(|_| Invalid)
	} else {
		_ = Stderr.line!("${$total.to_str()} problem(s)")
		Err(Invalid)
	}
}

## The runs an experiment resolves to, optionally just the one labelled `--only`.
runs! : { named : List((Str, Str)), positional : List(Str) } => Try(List(Load.Run), [Usage(Str), Failed(Str)])
runs! = |parsed| {
	path = parsed.positional.first() ?? return Err(Usage("apo: name an experiment.json"))
	loaded = Load.experiment!(path)?
	chosen = match option(parsed, "--only") {
		Ok(label) => loaded.runs.keep_if(|r| r.label == label)
		Err(_) => loaded.runs
	}
	if chosen.is_empty() Err(Failed("${path}: no runs (check models and --only)")) else Ok(chosen)
}

plan! = |words| {
	parsed = options(words, ["--help"])?
	if has_flag(parsed, "--help") {
		return Stdout.line!("usage: apo plan <experiment.json> [--only <label>]\n\nLists each run's directory and, per step, how many calls are answered by its store and how many would go to the model, with an upper-bound cost from the models' prices. Makes no calls.")
	}
	for run in runs!(parsed)? {
		report = Execute.run!(run, version, Dry)?
		Stdout.line!("${report.label}  ${report.dir}")?
		for s in report.steps {
			Stdout.line!("  ${s.kind}: ${s.items.to_str()} item(s), ${s.cached.to_str()} stored, ${s.planned.to_str()} to call (≤ $${Execute.money(s.estimate)})")?
		}
	}
	Ok({})
}

run_experiment! = |words| {
	parsed = options(words, ["--paid", "--help"])?
	if has_flag(parsed, "--help") {
		return Stdout.line!("usage: apo run <experiment.json> [--paid] [--only <label>]\n\nRuns every model and prompt variant, resuming from each run's store. Calls to providers with an API key need --paid. A run stops at its budget or at an item that fails its checks every attempt; rerunning resumes it.")
	}
	var $failed = Bool.False
	for run in runs!(parsed)? {
		report = Execute.run!(run, version, Live({ paid: has_flag(parsed, "--paid") }))?
		called = report.steps.map(|s| s.called).sum()
		failed = report.steps.map(|s| s.failed).sum()
		cached = report.steps.map(|s| s.cached).sum()
		Stdout.line!("${report.label}: ${report.status}; ${called.to_str()} call(s), ${cached.to_str()} from the store, ${failed.to_str()} item(s) failed, $${Execute.money(report.cost)} spent; ${report.dir}")?
		if report.status != "completed" {
			$failed = Bool.True
		}
	}
	if $failed Err(Invalid) else Ok({})
}

gold! = |words| {
	parsed = options(words, ["--help"])?
	match parsed.positional {
		["fetch", manifest_path] => {
			manifest = Gold.manifest(Io.json!(manifest_path)?).map_err(|m| Failed("${manifest_path}: ${m}"))?
			files = Evaluate.fetch!(manifest)?
			for (name, path) in files {
				Stdout.line!("${name}: ${path}")?
			}
			Stdout.line!("licence: ${manifest.license}")
		}
		_ => Stdout.line!("usage: apo gold fetch <gold.json>\n\nDownloads a gold manifest's files into the cache (APO_CACHE, else ~/.cache/apo) and checks each against its pinned SHA-256.")
	}
}

eval! = |words| {
	parsed = options(words, ["--json", "--help"])?
	manifest_path = match option(parsed, "--gold") {
		Ok(p) => p
		Err(_) => return Stdout.line!("usage: apo eval <run-dir>... --gold <gold.json> [--json]\n\nScores each run against a gold set and writes the scores to <run-dir>/eval/<gold>.json.")
	}
	manifest = Gold.manifest(Io.json!(manifest_path)?).map_err(|m| Failed("${manifest_path}: ${m}"))?
	files = Evaluate.fetch!(manifest)?
	for dir in parsed.positional {
		run = Evaluate.output!(dir)?
		scores = Evaluate.score!(manifest, files, run)?
		record = JsonValue.object([("run", JsonValue.str(dir)), ("label", JsonValue.str(run.label)), ("gold", JsonValue.str(manifest.name)), ("license", JsonValue.str(manifest.license))].concat(scores))
		Io.write!("${dir}/eval/${manifest.name}.json", JsonValue.pretty(record))?
		if has_flag(parsed, "--json") {
			Stdout.line!(JsonValue.encode(record))?
		} else {
			Stdout.line!("${run.label} vs ${manifest.name}")?
			for (name, value) in scores {
				Stdout.line!("  ${name}: ${JsonValue.encode(value)}")?
			}
		}
	}
	Ok({})
}

compare! = |words| {
	parsed = options(words, ["--paid", "--help"])?
	dirs = parsed.positional
	help = "usage:\n  apo compare <run-dir>... --judge <judge.json> --out <dir> [--paid]   a judge model's pairwise preferences\n  apo compare <run-dir>... --export-preferences <sheet.tsv>            a blinded sheet for reviewers\n  apo compare --import-preferences <sheet.tsv>... --key <sheet.tsv.key.json> --out <dir>\n  apo compare <run-dir>... --export-mqm <sheet.tsv>                    an MQM error-annotation sheet\n  apo compare --import-mqm <sheet.tsv> --key <sheet.tsv.key.json>\n\nRuns are compared on passage translations when all have them, else on sentence translations. A judge sees each\npair in both orders; orders that disagree count as a tie. Rankings are Bradley–Terry strengths."
	if has_flag(parsed, "--help") {
		return Stdout.line!(help)
	}
	match (option(parsed, "--judge"), option(parsed, "--export-preferences"), option(parsed, "--import-preferences"), option(parsed, "--export-mqm"), option(parsed, "--import-mqm")) {
		(Ok(judge), _, _, _, _) => Compare.judge!(dirs, judge, option(parsed, "--out") ?? "compare", has_flag(parsed, "--paid"))
		(_, Ok(sheet), _, _, _) => Compare.export_preferences!(dirs, sheet)
		(_, _, Ok(sheet), _, _) => Compare.import_preferences!(dirs.prepend(sheet), option(parsed, "--key") ?? "${sheet}.key.json", option(parsed, "--out") ?? "compare")
		(_, _, _, Ok(sheet), _) => Compare.export_mqm!(dirs, sheet)
		(_, _, _, _, Ok(sheet)) => Compare.import_mqm!(sheet, option(parsed, "--key") ?? "${sheet}.key.json")
		_ => Stdout.line!(help)
	}
}

export! = |words| {
	parsed = options(words, ["--help"])?
	match parsed.positional {
		[run_dir, dest] if !has_flag(parsed, "--help") => Archive.export!(run_dir, dest, version)
		_ => Stdout.line!("usage: apo export <run-dir> <work-dir>\n\nWrites a completed run as an archive work folder: output.conllu, units.jsonl, config.json (the run, apo version\nand prompts it came from), costs.tsv, and the run's manifest as apo-manifest.json.")
	}
}

adopt! = |words| {
	parsed = options(words, ["--help"])?
	match parsed.positional {
		[work] if !has_flag(parsed, "--help") => Archive.adopt!(work, option(parsed, "--runs") ?? "runs", version)
		_ => Stdout.line!("usage: apo adopt <work-dir> [--runs <dir>]\n\nWraps a work folder made before apo (output.conllu, units.jsonl, config.json) as a run under <dir>/adopted/,\nmarked not replayable, so apo eval and apo compare can score it next to new runs.")
	}
}

seed! = |words| {
	parsed = options(words, ["--help"])?
	work = match option(parsed, "--from") {
		Ok(w) if !has_flag(parsed, "--help") => w
		_ => return Stdout.line!("usage: apo seed <experiment.json> --from <work-dir> [--only <label>]\n\nFills each run's store from an archive work folder made before apo (output.conllu, units.jsonl): every call the\nrun would make is answered with what the work already holds, checked like any reply, until the work runs out.\nA later apo run then calls the model only for what the work lacks.")
	}
	for run in runs!(parsed)? {
		report = Execute.run!(run, version, Seed(work))?
		stored = report.steps.map(|s| s.cached).sum()
		Stdout.line!("${report.label}: ${stored.to_str()} item(s) from ${work}; ${report.status}; ${report.dir}")?
	}
	Ok({})
}
