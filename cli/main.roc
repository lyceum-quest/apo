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
import apo.JsonValue
import apo.Validate

import Execute
import Io
import Load

import "../VERSION" as raw_version : Str

version = raw_version.trim()

usage =
	\\usage: apo <command> [options]
	\\
	\\commands:
	\\  validate [--profile <profile.json>] [--json] <file.conllu>...   check CoNLL-U files
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
		cached = report.steps.map(|s| s.cached).sum()
		Stdout.line!("${report.label}: ${report.status}; ${called.to_str()} call(s), ${cached.to_str()} from the store, $${Execute.money(report.cost)} spent; ${report.dir}")?
		if report.status != "completed" {
			$failed = Bool.True
		}
	}
	if $failed Err(Invalid) else Ok({})
}
