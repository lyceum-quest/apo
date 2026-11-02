# Reads the configuration and the works directory, and resolves them into jobs: one per work and model, each with
# its rendered prompts. Paths in the configuration are relative to its folder.
import apo.Config
import apo.Conllu
import apo.Dataset
import apo.JsonValue
import apo.Provider
import apo.Steps
import apo.Template

import Io

Load :: [].{
	Step : { kind : Steps.Kind, system : Str, max_tokens : U64 }

	Work : { name : Str, spec : Dataset.Spec, sentences : List(Conllu.Sentence), passages : List(Dataset.Passage), has_refs : Bool }

	Job : { work : Work, model : Provider.Model, translate : Step, gloss : Step, passage : Step, dir : Str, attempts : U64, timeout_seconds : U64, author : Str }

	## Prompt templates, by step.
	Prompts : { translate : Str, gloss : Str, passage : Str }

	## The configuration file: `given` (from --config), else $APO_CONFIG, else $XDG_CONFIG_HOME/apo/config.json, else
	## ~/.config/apo/config.json.
	config_path! : Str => Str
	config_path! = |given| {
		if given != "" {
			return given
		}
		explicit = Io.env!("APO_CONFIG")
		if explicit != "" {
			return explicit
		}
		xdg = Io.env!("XDG_CONFIG_HOME")
		if (xdg != "") "${xdg}/apo/config.json" else "${Io.env!("HOME")}/.config/apo/config.json"
	}

	## The jobs a run makes: every work and model, or only those named in `works` and `models`.
	jobs! : Str, Prompts, List(Str), List(Str) => Try(List(Job), [Failed(Str)])
	jobs! = |path, defaults, works, models| {
		if !Io.exists!(path) {
			return Err(Failed("no configuration at ${path}; run `apo init` first"))
		}
		dir = Io.dir_of(path)
		settings = Config.parse(Io.json!(path)?).map_err(|m| Failed("${path}: ${m}"))?
		# A command named by a relative path is relative to the configuration, like every other path.
		all_models = settings.models.map(
			|m| match m.provider.protocol {
				Command([program, .. as rest]) if program.contains("/") => { ..m, provider: { ..m.provider, protocol: Command(rest.prepend(Io.join(dir, program))) } }
				_ => m
			},
		)
		chosen_models = pick(all_models.map(|m| m.name), models, "model")?
		works_dir = Io.join(dir, settings.works_dir)
		available = Io.list!(works_dir).keep_if(|p| p.ends_with(".conllu")).map(Io.stem).sort_with(JsonValue.compare)
		if available.is_empty() {
			return Err(Failed("${works_dir} has no .conllu files"))
		}
		for w in settings.works {
			if !available.contains(w.name) {
				return Err(Failed("${path}: works.${w.name} names no work in ${works_dir}"))
			}
		}
		prompts = prompts!(Io.join(dir, settings.prompts_dir), settings.prompts_dir, defaults)?
		var $jobs = []
		for name in pick(available, works, "work")? {
			separator = match settings.works.keep_if(|w| w.name == name) {
				[w, ..] => w.label_separator
				[] => "."
			}
			work = work!(works_dir, name, separator)?
			context = work.context
			for model in all_models.keep_if(|m| chosen_models.contains(m.name)) {
				step = |kind, template, max_tokens| {
					system = Template.render(template.trim(), [("title", work.value.spec.title), ("context", context)]).map_err(|e| Failed("${Steps.name(kind)} prompt: ${e}"))?
					Ok({ kind, system, max_tokens })
				}
				l = settings.limits
				$jobs = $jobs.append({
					work: work.value,
					model,
					translate: step(TranslateSentence, prompts.translate, l.translate_tokens)?,
					gloss: step(GlossTokens, prompts.gloss, l.gloss_tokens)?,
					passage: step(TranslatePassage, prompts.passage, l.passage_tokens)?,
					dir: "${Io.join(dir, settings.output_dir)}/${name}/${model.name}",
					attempts: l.attempts,
					timeout_seconds: l.timeout_seconds,
					author: settings.author,
				})
			}
		}
		Ok($jobs)
	}

	## `wanted` (all of `names` when empty), or an error naming the first unknown one.
	pick : List(Str), List(Str), Str -> Try(List(Str), [Failed(Str)])
	pick = |names, wanted, what| {
		for w in wanted {
			if !names.contains(w) {
				return Err(Failed("no ${what} named ${w}; there are ${Str.join_with(names, ", ")}"))
			}
		}
		Ok(if (wanted.is_empty()) names else names.keep_if(|n| wanted.contains(n)))
	}

	## The prompt templates: each file in the prompts folder that exists, else the built-in one.
	prompts! : Str, Str, Prompts => Try(Prompts, [Failed(Str)])
	prompts! = |folder, configured, defaults| {
		if configured == "" {
			return Ok(defaults)
		}
		if !Io.exists!(folder) {
			return Err(Failed("prompts_dir ${folder} does not exist"))
		}
		one! = |name, default| if (Io.exists!("${folder}/${name}.md")) Io.read!("${folder}/${name}.md") else Ok(default)
		Ok({ translate: one!("translate", defaults.translate)?, gloss: one!("gloss", defaults.gloss)?, passage: one!("passage", defaults.passage)? })
	}

	## A work: `<name>.conllu`, with an optional `<name>.context.md` (a first line `# <Title>` sets the title) and an
	## optional `<name>.refs.tsv` (token<TAB>citation lines) for passage translations.
	work! : Str, Str, Str => Try({ value : Work, context : Str }, [Failed(Str)])
	work! = |folder, name, separator| {
		conllu_path = "${folder}/${name}.conllu"
		sentences = Conllu.parse(Io.read!(conllu_path)?).map_err(|e| Failed("${conllu_path}:${e.line.to_str()}: ${e.message}"))?
		if sentences.is_empty() {
			return Err(Failed("${conllu_path} has no sentences"))
		}
		context_path = "${folder}/${name}.context.md"
		raw = if (Io.exists!(context_path)) Io.read!(context_path)? else ""
		titled = match raw.trim().split_first("\n") {
			Ok({ before, after }) if before.starts_with("# ") => { title: before.drop_prefix("# ").trim(), context: after.trim() }
			_ => if (raw.trim().starts_with("# ")) { title: raw.trim().drop_prefix("# ").trim(), context: "" } else { title: name, context: raw.trim() }
		}
		spec = { ..Dataset.detect(titled.title, sentences), label_separator: separator }
		refs_path = "${folder}/${name}.refs.tsv"
		has_refs = Io.exists!(refs_path)
		passages = if (has_refs) Dataset.from_refs(spec, Io.read!(refs_path)?, sentences).map_err(|m| Failed("${refs_path}: ${m}"))? else []
		Ok({ value: { name, spec, sentences, passages, has_refs }, context: titled.context })
	}
}
