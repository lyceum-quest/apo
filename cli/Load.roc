# Reads an experiment and everything it names, and resolves it into runs: one per model and prompt variant, each with
# its rendered prompts, dataset, and limits. Paths in a file are relative to that file's folder.
import apo.Conllu
import apo.Dataset
import apo.JsonValue
import apo.Provider
import apo.Steps
import apo.Template

import Io

Load :: [].{
	Step : { kind : Steps.Kind, prompt_file : Str, system : Str, max_tokens : U64, lang : Str, punctuation : List(Str) }

	Run : {
		experiment : Str,
		label : Str,
		model : Provider.Model,
		steps : List(Step),
		dataset : Dataset.Spec,
		sentences : List(Conllu.Sentence),
		passages : List(Dataset.Passage),
		reference : List(List(Str)),
		attempts : U64,
		timeout_seconds : U64,
		budget : Dec,
		runs_dir : Str,
		sources : List((Str, Str)),
	}

	experiment! : Str => Try({ name : Str, runs : List(Run) }, [Failed(Str)])
	experiment! = |path| {
		dir = Io.dir_of(path)
		json = Io.json!(path)?
		text = |key, default| (json.field(key) ?? JsonValue.str(default)).as_str() ?? default
		name = text("name", Io.stem(path))
		providers_path = Io.join(dir, text("providers", "providers.json"))
		configured = Provider.settings(Io.json!(providers_path)?).map_err(|m| Failed("${providers_path}: ${m}"))?
		# A command named by a relative path is relative to providers.json, like every other path.
		providers = configured.map(|p| match p.protocol {
			Command([program, .. as rest]) if program.contains("/") => { ..p, protocol: Command(rest.prepend(Io.join(Io.dir_of(providers_path), program))) }
			_ => p
		})
		dataset_path = Io.join(dir, text("dataset", "dataset.json"))
		dataset = dataset!(dataset_path)?
		pipeline_path = Io.join(dir, text("pipeline", "pipeline.json"))
		pipeline = Io.json!(pipeline_path)?
		limits = pipeline.field("limits") ?? JsonValue.object([])
		attempts = (limits.field("attempts") ?? JsonValue.Number("3")).as_u64() ?? 3
		timeout_seconds = (limits.field("timeout_seconds") ?? JsonValue.Number("180")).as_u64() ?? 180
		budget = (json.field("budget_usd") ?? JsonValue.Number("0")).as_dec() ?? 0
		runs_dir = Io.join(dir, text("runs", "runs"))

		var $fixed = [("title", dataset.spec.title)]
		var $sources = [("experiment.json", JsonValue.pretty(json)), ("providers.json", Io.read!(providers_path)?), ("dataset.json", Io.read!(dataset_path)?), ("pipeline.json", Io.read!(pipeline_path)?)]
		for (key, v) in (json.field("variables") ?? JsonValue.object([])).fields() {
			value = match v.as_str() {
				Ok(file) => {
					content = Io.read!(Io.join(dir, file))?
					$sources = $sources.append(("variables/${Io.stem(file)}.md", content))
					content.trim()
				}
				Err(_) => (v.field("text") ?? JsonValue.str("")).as_str() ?? ""
			}
			$fixed = $fixed.append((key, value))
		}
		var $variants = [{ label: "", values: [] }]
		for (key, options) in (json.field("variants") ?? JsonValue.object([])).fields() {
			var $next = []
			for v in $variants {
				for option in options.items() {
					file = option.as_str() ?? ""
					content = Io.read!(Io.join(dir, file))?
					$sources = $sources.append(("variants/${key}/${Io.stem(file)}.md", content))
					label = if v.label == "" Io.stem(file) else "${v.label}-${Io.stem(file)}"
					$next = $next.append({ label, values: v.values.append((key, content.trim())) })
				}
			}
			$variants = $next
		}

		var $runs = []
		for m in (json.field("models") ?? JsonValue.list([])).items() {
			model = Provider.model(m, providers).map_err(|e| Failed("${path}: ${e}"))?
			for variant in $variants {
				variables = $fixed.concat(variant.values)
				var $steps = []
				for s in (pipeline.field("steps") ?? JsonValue.list([])).items() {
					stext = |key, default| (s.field(key) ?? JsonValue.str(default)).as_str() ?? default
					kind = Steps.kind(stext("kind", "")).map_err(|e| Failed("${pipeline_path}: ${e}"))?
					prompt_file = Io.join(Io.dir_of(pipeline_path), stext("prompt", ""))
					template = Io.read!(prompt_file)?
					system = Template.render(template.trim(), variables).map_err(|e| Failed("${prompt_file}: ${e}"))?
					punctuation = (s.field("punctuation_upos") ?? JsonValue.strs(["u", "PUNCT"])).items().map(|u| u.as_str() ?? "")
					$steps = $steps.append({ kind, prompt_file, system, max_tokens: (s.field("max_tokens") ?? JsonValue.Number("1024")).as_u64() ?? 1024, lang: stext("lang", "en"), punctuation })
				}
				if $steps.is_empty() {
					return Err(Failed("${pipeline_path}: no steps"))
				}
				label = if variant.label == "" model.name else "${model.name}-${variant.label}"
				$runs = $runs.append({ experiment: name, label, model, steps: $steps, dataset: dataset.spec, sentences: dataset.sentences, passages: dataset.passages, reference: dataset.reference, attempts, timeout_seconds, budget, runs_dir, sources: $sources })
			}
		}
		for (prompt_name, prompt_text) in prompt_sources!(pipeline, pipeline_path)? {
			$sources = $sources.append((prompt_name, prompt_text))
		}
		Ok({ name, runs: $runs.map(|r| { ..r, sources: $sources }) })
	}

	prompt_sources! = |pipeline, pipeline_path| {
		var $out = []
		for s in (pipeline.field("steps") ?? JsonValue.list([])).items() {
			file = (s.field("prompt") ?? JsonValue.str("")).as_str() ?? ""
			$out = $out.append(("prompts/${Io.stem(file)}.md", Io.read!(Io.join(Io.dir_of(pipeline_path), file))?))
		}
		Ok($out)
	}

	## A dataset's spec, sentences, passages (all of them; runs apply the limit), and reference token lines.
	dataset! : Str => Try({ spec : Dataset.Spec, sentences : List(Conllu.Sentence), passages : List(Dataset.Passage), reference : List(List(Str)) }, [Failed(Str)])
	dataset! = |path| {
		dir = Io.dir_of(path)
		raw = Dataset.spec(Io.json!(path)?).map_err(|m| Failed("${path}: ${m}"))?
		spec = { ..raw, input: Io.join(dir, raw.input), reference: if raw.reference == "" "" else Io.join(dir, raw.reference) }
		input = Io.read!(spec.input)?
		sentences = match spec.format {
			Conllu => Conllu.parse(input).map_err(|e| Failed("${spec.input}:${e.line.to_str()}: ${e.message}"))?
			Tokens => Dataset.from_tokens(input)
		}
		passages = match spec.passages {
			BySentence => Dataset.by_sentence(spec, sentences)
			Refs(file) => Dataset.from_refs(spec, Io.read!(Io.join(dir, file))?, sentences).map_err(|m| Failed("${file}: ${m}"))?
			File(file) => Dataset.from_file(Io.json!(Io.join(dir, file))?).map_err(|m| Failed("${file}: ${m}"))?
		}
		reference = if spec.reference == "" [] else Dataset.from_tokens(Io.read!(spec.reference)?).map(|s| s.rows.map(|r| r.form))
		Ok({ spec, sentences, passages, reference })
	}
}
