# apo: gloss and translate Ancient Greek CoNLL-U with language models.
app [main!] {
	apo: "../package/main.roc",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
}

import pf.Env
import pf.OsStr
import pf.Path
import pf.Stderr
import pf.Stdin
import pf.Stdout
import apo.JsonValue

import Execute
import Io
import Load

import "../VERSION" as raw_version : Str
import "../prompts/translate.md" as translate_prompt : Str
import "../prompts/gloss.md" as gloss_prompt : Str
import "../prompts/passage.md" as passage_prompt : Str

version = raw_version.trim()

defaults = { translate: translate_prompt, gloss: gloss_prompt, passage: passage_prompt }

usage =
	\\usage: apo <command> [options]
	\\
	\\commands:
	\\  init    write a configuration: provider, models, works and output folders
	\\  run     gloss and translate the next sentences of every work with every model
	\\
	\\Run `apo <command> --help` for a command's options.

main! : List(OsStr) => Try({}, [Exit(I32)])
main! = |args| {
	shown = args.map(OsStr.display)
	match command!(shown) {
		Ok({}) => Ok({})
		Err(Usage(message)) => {
			_ = Stderr.line!(message)
			Err(Exit(2))
		}
		Err(Failed(message)) => {
			_ = Stderr.line!("apo: ${message}")
			Err(Exit(1))
		}
		Err(other) => {
			_ = Stderr.line!("apo: ${Str.inspect(other)}")
			Err(Exit(1))
		}
	}
}

command! = |shown| match shown {
	["init", .. as rest] => init!(rest)
	["run", .. as rest] => run!(rest)
	["--version"] => Stdout.line!(version)
	["--help"] | ["-h"] | ["help"] | [] => Stdout.line!(usage)
	[name, ..] => Err(Usage("apo: unknown command ${name}\n\n${usage}"))
}

## Options as (`--name`, value) pairs and the remaining positional arguments. `flags` take no value; `valued` take one;
## any other option is an error.
options : List(Str), List(Str), List(Str), Str -> Try({ named : List((Str, Str)), positional : List(Str) }, [Usage(Str)])
options = |words, flags, valued, help| {
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
				} else if valued.contains(word) {
					$pending = Ok(word)
				} else {
					return Err(Usage("apo: unknown option ${word}\n\n${help}"))
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

## Every value given for an option.
values = |parsed, name| parsed.named.keep_if(|(n, _)| n == name).map(|(_, v)| v)

option = |parsed, name| values(parsed, name).first() ?? ""

has_flag = |parsed, name| parsed.named.any(|(n, _)| n == name)

## Rejects positional arguments, which no command takes.
no_arguments = |parsed, help| if (parsed.positional.is_empty()) Ok({}) else Err(Usage("apo: unexpected argument ${parsed.positional.first() ?? ""}\n\n${help}"))

run_help =
	\\usage: apo run [--count N] [--work <name>]... [--model <name>]... [--fresh] [--config <config.json>]
	\\
	\\Translates and glosses the next N sentences (default 10) of every work with every model, in order, then
	\\translates each citation passage those sentences complete. Sentences already done are not called again: every
	\\accepted reply is kept in the output folder's replies.jsonl. Outputs go to <output_dir>/<work>/<model>/.
	\\
	\\A run stops if a work's output was made with a different model, prompt, context or limit; --fresh starts that
	\\work over instead.

run! = |words| {
	parsed = options(words, ["--fresh", "--help"], ["--count", "--work", "--model", "--config"], run_help)?
	if has_flag(parsed, "--help") {
		return Stdout.line!(run_help)
	}
	no_arguments(parsed, run_help)?
	count = match option(parsed, "--count") {
		"" => 10
		text => match U64.from_str(text) {
			Ok(n) if n > 0 => n
			_ => return Err(Usage("apo: --count must be a positive whole number"))
		}
	}
	path = Load.config_path!(option(parsed, "--config"))
	for job in Load.jobs!(path, defaults, values(parsed, "--work"), values(parsed, "--model"))? {
		report = Execute.run!(job, count, has_flag(parsed, "--fresh"), version)?
		passages = if (job.work.has_refs) ", ${report.passages.to_str()} of ${report.total_passages.to_str()} passages" else ""
		Stdout.line!("${job.work.name}/${job.model.name}: ${report.generated.to_str()} new; ${report.sentences.to_str()} of ${report.total.to_str()} sentences${passages}; ${report.dir}")?
	}
	Ok({})
}

init_help =
	\\usage: apo init [--claude-cli | --base-url <url> [--key-env <VAR>]] [--model <id>]... [--works <dir>]
	\\                [--output <dir>] [--name <name>] [--email <email>] [--config <config.json>] [--force]
	\\
	\\Writes the configuration apo run reads ($XDG_CONFIG_HOME/apo/config.json, else ~/.config/apo/config.json).
	\\In a terminal it asks for anything not given as an option; otherwise it uses the defaults: the Claude Code
	\\login (claude -p) with model sonnet, ./works, and ./apo-output.
	\\
	\\Providers: --claude-cli uses your Claude Code login. --base-url names any OpenAI-compatible API (OpenRouter,
	\\a local llama.cpp, vLLM or Ollama server); --key-env names the environment variable holding its key.

init! = |words| {
	parsed = options(words, ["--claude-cli", "--force", "--help"], ["--base-url", "--key-env", "--model", "--works", "--output", "--name", "--email", "--config"], init_help)?
	if has_flag(parsed, "--help") {
		return Stdout.line!(init_help)
	}
	no_arguments(parsed, init_help)?
	path = Load.config_path!(option(parsed, "--config"))
	if Io.exists!(path) and !has_flag(parsed, "--force") {
		return Err(Failed("${path} exists; pass --force to replace it"))
	}
	interactive = Io.stdin_is_terminal!()
	ask! = |given, question, default| {
		if given != "" or !interactive {
			return if (given != "") given else default
		}
		shown_default = if (default == "") "" else " [${default}]"
		_ = Stderr.write!("${question}${shown_default}: ")
		answer = (Stdin.line!() ?? "").trim()
		if (answer == "") default else answer
	}
	api = if has_flag(parsed, "--claude-cli") {
		Bool.False
	} else if option(parsed, "--base-url") != "" {
		Bool.True
	} else {
		ask!("", "Provider: 1) your Claude Code login (claude -p)  2) an OpenAI-compatible API (OpenRouter, a local server)", "1") == "2"
	}
	provider = if api {
		base_url = ask!(option(parsed, "--base-url"), "API base URL", "https://openrouter.ai/api/v1")
		key_env = ask!(option(parsed, "--key-env"), "Environment variable holding the API key (none for a local server)", "OPENROUTER_API_KEY")
		key = if (key_env == "none") [] else [("key_env", JsonValue.str(key_env))]
		("api", JsonValue.object([("protocol", JsonValue.str("openai-chat")), ("base_url", JsonValue.str(base_url))].concat(key)))
	} else {
		("claude", JsonValue.object([("protocol", JsonValue.str("claude-cli"))]))
	}
	(provider_name, _) = provider
	given_models = Str.join_with(values(parsed, "--model"), ",")
	ids = ask!(given_models, "Model IDs, comma-separated", if (api) "anthropic/claude-sonnet-5" else "sonnet").split_on(",").map(|id| id.trim()).keep_if(|id| id != "")
	models = ids.map(
		|id| {
			name = match id.split_last("/") {
				Ok({ before: _, after }) => after
				Err(_) => id
			}
			options_json = if (api) [("options", JsonValue.object([("temperature", JsonValue.Number("0"))]))] else []
			JsonValue.object([("name", JsonValue.str(name)), ("provider", JsonValue.str(provider_name)), ("id", JsonValue.str(id))].concat(options_json))
		},
	)
	cwd = Path.display(Env.cwd!() ?? Path.unix("."))
	absolute = |p| if (p.starts_with("/")) p else "${cwd}/${p.drop_prefix("./")}"
	works = absolute(ask!(option(parsed, "--works"), "Works folder (one <work>.conllu per text)", "works"))
	output = absolute(ask!(option(parsed, "--output"), "Output folder", "apo-output"))
	name = ask!(option(parsed, "--name"), "Your name, credited in outputs (optional)", "")
	email = ask!(option(parsed, "--email"), "Your email (optional)", "")
	author = [("name", name), ("email", email)].keep_if(|(_, v)| v != "").map(|(k, v)| (k, JsonValue.str(v)))
	config = JsonValue.object(
		[
			("providers", JsonValue.object([provider])),
			("models", JsonValue.list(models)),
			("works_dir", JsonValue.str(works)),
			("output_dir", JsonValue.str(output)),
		].concat(if (author.is_empty()) [] else [("author", JsonValue.object(author))]),
	)
	Io.write!(path, "${JsonValue.pretty(config)}\n")?
	Io.mkdir!(works)?
	Stderr.line!("wrote ${path}\n\nPut Opera Graeca Adnotata CoNLL-U files in ${works} (optionally <work>.context.md and <work>.refs.tsv\nbeside each), then run: apo run --count 5")
}
