# apo: run language models over CoNLL-U, validate the output, and measure it.
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	apo: "../package/main.roc",
}

import pf.OsStr
import pf.Path
import pf.Stderr
import pf.Stdout
import apo.JsonValue
import apo.Validate

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
