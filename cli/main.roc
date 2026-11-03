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
import apo.Catalog
import apo.JsonValue
import apo.Picker
import apo.Provider

import Auth
import Execute
import Io
import Load
import Prompt

import "../VERSION" as raw_version : Str
import "../providers.json" as raw_providers : Str
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
	\\  login   store a provider's API key
	\\  logout  remove a stored API key
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
	["login", .. as rest] => login!(rest)
	["logout", .. as rest] => logout!(rest)
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
	\\usage: apo init [--provider <id> | --claude-cli | --base-url <url> [--key-env <VAR>]] [--model <id>]...
	\\                [--works <dir>] [--output <dir>] [--name <name>] [--email <email>] [--config <config.json>] [--force]
	\\
	\\Writes the configuration apo run reads ($XDG_CONFIG_HOME/apo/config.json, else ~/.config/apo/config.json).
	\\In a terminal it asks for anything not given: pick a provider from a list (type to filter), paste its key if
	\\it needs one, then pick a model. Otherwise give the provider and models as options.
	\\
	\\Local models: pick Ollama, llama.cpp, LM Studio or vLLM, or use --base-url for a server anywhere on your
	\\network; apo lists the models the server has. --provider takes an ID from the list; --key-env names the
	\\environment variable holding the key of a --base-url server.

login_help =
	\\usage: apo login [<provider>] [--config <config.json>]
	\\
	\\Stores a provider's API key in $XDG_DATA_HOME/apo/auth.json (else ~/.local/share/apo/auth.json), readable only by
	\\you. In a terminal it asks without showing the key; otherwise it reads the key from standard input. A stored
	\\key is used before the provider's environment variable. Remove one with `apo logout <provider>`.

logout_help =
	\\usage: apo logout <provider>
	\\
	\\Removes a provider's stored API key.

## The list as the picker shows it, with a mark where a key is already at hand.
entry_items! : List(Catalog.Entry) => Try(List(Picker.Item), [Failed(Str)])
entry_items! = |entries| {
	stored = Auth.read!()?
	var $items = []
	for e in entries {
		ready = stored.any(|(name, _)| name == e.id) or (e.key_env != "" and Io.env!(e.key_env) != "")
		$items = $items.append({ label: if (ready) "${e.name}  (key found)" else e.name, value: e.id })
	}
	Ok($items)
}

find : List(Catalog.Entry), Str -> Try(Catalog.Entry, [Failed(Str)])
find = |entries, id| match entries.keep_if(|e| e.id == id) {
	[e, ..] => Ok(e)
	[] => Err(Failed("no provider ${id}; run `apo init` in a terminal to see the list, or use --base-url"))
}

entries_of = || Catalog.parse(raw_providers).map_err(|m| Failed("providers.json: ${m}"))

init! = |words| {
	parsed = options(words, ["--claude-cli", "--force", "--help"], ["--provider", "--base-url", "--key-env", "--model", "--works", "--output", "--name", "--email", "--config"], init_help)?
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
	entries = entries_of()?
	entry = if has_flag(parsed, "--claude-cli") {
		find(entries, "claude-code")?
	} else if option(parsed, "--base-url") != "" {
		find(entries, "server")?
	} else if option(parsed, "--provider") != "" {
		find(entries, option(parsed, "--provider"))?
	} else if interactive {
		find(entries, Prompt.pick!("Provider", entry_items!(entries)?, Bool.False)?)?
	} else {
		find(entries, "claude-code")?
	}
	base_url = if entry.local {
		ask!(option(parsed, "--base-url"), "Server URL (ending in /v1)", entry.base_url)
	} else {
		entry.base_url
	}
	if entry.local and base_url == "" {
		return Err(Failed("a server needs a URL: pass --base-url"))
	}
	key_env = if (option(parsed, "--key-env") != "") option(parsed, "--key-env") else entry.key_env
	provider = Catalog.config(entry, base_url, key_env)
	settings = Provider.settings(entry.id, provider).map_err(|m| Failed(m))?
	if interactive and Catalog.takes_key(entry) and Auth.key!(settings)? == "" {
		hint = if (key_env == "") "Enter for none" else "Enter to set ${key_env} yourself"
		key = Prompt.secret!("API key for ${entry.name} (${hint})")?
		if key != "" {
			Auth.store!(entry.id, key)?
		}
	}
	given_models = values(parsed, "--model").map(|id| id.trim()).keep_if(|id| id != "")
	ids = if !given_models.is_empty() {
		given_models
	} else {
		choose_model!(entry, settings, interactive, ask!)?
	}
	models = ids.map(
		|id| {
			name = match id.split_last("/") {
				Ok({ before: _, after }) => after
				Err(_) => id
			}
			# Hosted models increasingly reject `temperature`; a local one is deterministic only with it.
			options_json = if (entry.local) [("options", JsonValue.object([("temperature", JsonValue.Number("0"))]))] else []
			JsonValue.object([("name", JsonValue.str(name)), ("provider", JsonValue.str(entry.id)), ("id", JsonValue.str(id))].concat(options_json))
		},
	)
	cwd = Path.display(Env.cwd!() ?? Path.unix("."))
	absolute = |p| if (p.starts_with("/")) p else "${cwd}/${p.drop_prefix("./")}"
	works = absolute(ask!(option(parsed, "--works"), "Works folder (one <work>.conllu per text)", "works"))
	output = absolute(ask!(option(parsed, "--output"), "Output folder", "apo-output"))
	name = ask!(option(parsed, "--name"), "Your name, credited in outputs (optional)", "")
	email = ask!(option(parsed, "--email"), "Your email (optional)", "")
	author = [("name", name), ("email", email)].keep_if(|(_, v)| v != "").map(|(k, v)| (k, JsonValue.str(v)))
	# A local model on modest hardware can take minutes over one sentence.
	limits = if (entry.local) [("limits", JsonValue.object([("timeout_seconds", JsonValue.u64(600))]))] else []
	config = JsonValue.object(
		[
			("providers", JsonValue.object([(entry.id, provider)])),
			("models", JsonValue.list(models)),
			("works_dir", JsonValue.str(works)),
			("output_dir", JsonValue.str(output)),
		].concat(limits).concat(if (author.is_empty()) [] else [("author", JsonValue.object(author))]),
	)
	Io.write!(path, "${JsonValue.pretty(config)}\n")?
	Io.mkdir!(works)?
	Stderr.line!("wrote ${path}\n\nPut CoNLL-U files in ${works}, one <work>.conllu per text (optionally <work>.context.md and\n<work>.refs.tsv beside each), then run: apo run --count 5")
}

## The model IDs to use: picked from what the provider lists, or typed when it lists none or cannot be reached.
choose_model! = |entry, settings, interactive, ask!| {
	if entry.protocol == "claude-cli" {
		return Ok([ask!("", "Model", "sonnet")])
	}
	if !interactive {
		return Err(Failed("name a model with --model"))
	}
	key = Auth.key!(settings)?
	listed = match Execute.models!(settings, key) {
		Ok(ids) => ids
		Err(NoListing) => []
		Err(Unreachable(why)) => {
			if entry.local {
				_ = Stderr.line!("Could not list models (is the server running?): ${why}")
			} else {
				_ = Stderr.line!("Could not list models: ${why}")
			}
			[]
		}
	}
	if listed.is_empty() {
		typed = ask!("", "Model ID", "")
		return if (typed == "") Err(Failed("no model given")) else Ok([typed])
	}
	Ok([Prompt.pick!("Model", listed.map(|id| { label: id, value: id }), Bool.True)?])
}

login! = |words| {
	parsed = options(words, ["--help"], ["--config"], login_help)?
	if has_flag(parsed, "--help") {
		return Stdout.line!(login_help)
	}
	entries = entries_of()?
	interactive = Io.stdin_is_terminal!()
	id = match parsed.positional {
		[one] => one
		[] => if (interactive) Prompt.pick!("Provider", entry_items!(entries.keep_if(Catalog.takes_key))?, Bool.False)? else return Err(Usage(login_help))
		_ => return Err(Usage(login_help))
	}
	key = if (interactive) Prompt.secret!("API key for ${id}")? else (Stdin.line!() ?? "").trim()
	if key == "" {
		return Err(Failed("no key given"))
	}
	Auth.store!(id, key)?
	Stderr.line!("stored the key for ${id} in ${Auth.path!()}")
}

logout! = |words| {
	parsed = options(words, ["--help"], [], logout_help)?
	if has_flag(parsed, "--help") {
		return Stdout.line!(logout_help)
	}
	match parsed.positional {
		[id] => if (Auth.remove!(id)?) Stderr.line!("removed the key for ${id}") else Err(Failed("no stored key for ${id}"))
		_ => Err(Usage(logout_help))
	}
}
