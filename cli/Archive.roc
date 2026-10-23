# Moving runs in and out of an archive's layout: one folder per work with output.conllu, units.jsonl, config.json and
# costs.tsv (Archeion's conllu/generated/<work>-<model>/).
#   export: a run's outputs into such a folder; config.json names the run and apo version it came from.
#   adopt:  such a folder, made before apo, as a run without a store: its outputs and settings, not replayable.
import pf.Stdout

import apo.Conllu
import apo.JsonValue

import Io

Archive :: [].{
	export! : Str, Str, Str => Try({}, [Failed(Str)])
	export! = |run_dir, dest, version| {
		manifest = Io.json!("${run_dir}/manifest.json")?
		field = |obj, key| (obj.field(key) ?? JsonValue.str("")).as_str() ?? ""
		dataset = manifest.field("dataset") ?? JsonValue.object([])
		model = manifest.field("model") ?? JsonValue.object([])
		status = field(manifest, "status")
		if status != "completed" {
			return Err(Failed("${run_dir} is ${status}; export a completed run"))
		}
		conllu = Io.read!("${run_dir}/output/${field(dataset, "name")}.conllu")?
		_ = Conllu.parse(conllu).map_err(|e| Failed("${run_dir}: ${e.message}"))?
		Io.write!("${dest}/output.conllu", conllu)?
		if Io.exists!("${run_dir}/output/units.jsonl") {
			Io.write!("${dest}/units.jsonl", Io.read!("${run_dir}/output/units.jsonl")?)?
		}
		var $prompts = []
		for file in Io.list!("${run_dir}/config/prompts") {
			$prompts = $prompts.append((Io.stem(file), JsonValue.str(Io.read!(file)?)))
		}
		config = JsonValue.object([
			("title", JsonValue.str(field(dataset, "title"))),
			("input", JsonValue.str(field(dataset, "input"))),
			("model", JsonValue.str(field(model, "id"))),
			("provider", JsonValue.str(field(model, "provider"))),
			("generator", JsonValue.str("apo ${version}")),
			("apo_run", JsonValue.str(field(manifest, "run"))),
			("prompts", JsonValue.object($prompts)),
		])
		Io.write!("${dest}/config.json", JsonValue.pretty(config))?
		var $costs = []
		for line in (Io.read!("${run_dir}/events.jsonl") ?? "").split_on("\n") {
			match JsonValue.decode(line) {
				Ok(e) if (e.field("cached") ?? JsonValue.bool(Bool.False)).as_bool() == Ok(Bool.False) => {
					$costs = $costs.append("${field(e, "step")}\t${JsonValue.encode(e.field("item") ?? JsonValue.null)}\t${JsonValue.encode(e.field("cost") ?? JsonValue.null)}\t${field(model, "protocol")}")
				}
				_ => {}
			}
		}
		Io.write!("${dest}/costs.tsv", Str.join_with($costs.map(|l| "${l}\n"), ""))?
		Io.write!("${dest}/apo-manifest.json", JsonValue.pretty(manifest))?
		Stdout.line!("exported ${run_dir} to ${dest}").map_err(|_| Failed("stdout"))
	}

	adopt! : Str, Str, Str => Try({}, [Failed(Str)])
	adopt! = |work, runs_dir, version| {
		config = Io.json!("${work}/config.json")?
		field = |key| (config.field(key) ?? JsonValue.str("")).as_str() ?? ""
		folder = Io.stem(work.drop_suffix("/"))
		name = folder.split_on("-").first() ?? folder
		dir = "${runs_dir}/adopted/${folder}"
		conllu = Io.read!("${work}/output.conllu")?
		sentences = Conllu.parse(conllu).map_err(|e| Failed("${work}: ${e.message}"))?
		Io.write!("${dir}/output/${name}.conllu", Conllu.serialize(sentences))?
		units = Io.read!("${work}/units.jsonl") ?? ""
		if units != "" {
			Io.write!("${dir}/output/units.jsonl", units)?
			passages = units.split_on("\n").keep_oks(|l| JsonValue.decode(l)).map(|u| JsonValue.object([("ref", u.field("ref") ?? JsonValue.str("")), ("label", u.field("label") ?? JsonValue.str("")), ("tokens", u.field("tokens") ?? JsonValue.list([]))]))
			Io.write!("${dir}/output/passages.jsonl", Str.join_with(passages.map(|p| "${JsonValue.encode(p)}\n"), ""))?
		}
		Io.write!("${dir}/config/original-config.json", JsonValue.pretty(config))?
		manifest = JsonValue.object([
			("apo", JsonValue.str(version)),
			("run", JsonValue.str("adopted:${folder}")),
			("experiment", JsonValue.str("adopted")),
			("label", JsonValue.str(folder)),
			("model", JsonValue.object([("name", JsonValue.str(field("model"))), ("provider", JsonValue.str("unknown")), ("protocol", JsonValue.str("unknown")), ("id", JsonValue.str(field("model"))), ("options", JsonValue.object([]))])),
			("dataset", JsonValue.object([("name", JsonValue.str(name)), ("title", JsonValue.str(field("title"))), ("input", JsonValue.str(field("input"))), ("passages", JsonValue.u64(units.split_on("\n").keep_if(|l| l.trim() != "").len())), ("token_ids", JsonValue.str("misc-first")), ("first_line", JsonValue.u64(1))])),
			("status", JsonValue.str("completed")),
			("replayable", JsonValue.bool(Bool.False)),
			("note", JsonValue.str("Made before apo: outputs and settings only, without the requests and replies that produced them.")),
		])
		Io.write!("${dir}/manifest.json", JsonValue.pretty(manifest))?
		Stdout.line!("adopted ${work} as ${dir} (not replayable)").map_err(|_| Failed("stdout"))
	}
}
