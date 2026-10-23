# Comparison of runs over the same dataset: blinded pairwise preferences between their translations, from a judge
# model (each pair asked in both orders; disagreeing orders count as a tie) or from reviewers through exported sheets,
# ranked by Bradley–Terry; and MQM error annotation per run, from sheets.
import pf.Stdout

import apo.Conllu
import apo.JsonValue
import apo.Metrics
import apo.Provider
import apo.Steps

import Evaluate
import Execute
import Io
import Load

Compare :: [].{
	## A translation to compare: the same item (passage ref or sentence number) in every run.
	Item : { id : Str, greek : Str, translations : List((Str, Str)) }

	## Items present in every run, from passage translations when all runs have them, else sentence translations.
	items! : List(Str) => Try({ labels : List(Str), items : List(Item) }, [Failed(Str)])
	items! = |dirs| {
		var $runs = []
		for dir in dirs {
			$runs = $runs.append(Evaluate.output!(dir)?)
		}
		labels = $runs.map(|r| r.label)
		first = $runs.first() ?? return Err(Failed("name at least two runs"))
		passages = $runs.all(|r| !r.units.is_empty())
		var $out = []
		if passages {
			for unit in first.units {
				translations = $runs.keep_oks(|r| match r.units.keep_if(|u| u.ref == unit.ref) {
					[u, ..] => Ok((r.label, u.prose))
					[] => Err(Missing)
				})
				if translations.len() == $runs.len() {
					$out = $out.append({ id: unit.ref, greek: passage_text(first, unit.ref), translations })
				}
			}
		} else {
			var $i = 0
			for s in first.sentences {
				translations = $runs.keep_oks(|r| match r.sentences.get($i) {
					Ok(other) => Conllu.comment(other, "prose_translation").map_ok(|p| (r.label, p))
					Err(_) => Err(Missing)
				})
				if translations.len() == $runs.len() {
					$out = $out.append({ id: ($i + 1).to_str(), greek: Conllu.text(s), translations })
				}
				$i = $i + 1
			}
		}
		Ok({ labels, items: $out })
	}

	passage_text : Evaluate.Output, Str -> Str
	passage_text = |run, ref| {
		tokens = match run.passages.keep_if(|p| p.ref == ref) {
			[p, ..] => p.tokens
			[] => []
		}
		var $forms = []
		var $i = 0.U64
		for s in run.sentences {
			for r in s.rows.keep_if(Conllu.is_word) {
				id = if run.token_ids == "misc-first" (Conllu.misc_items(r).first() ?? "") else "${($i + 1).to_str()}:${r.id}"
				if tokens.contains(id) {
					$forms = $forms.append(r.form)
				}
			}
			$i = $i + 1
		}
		Str.join_with($forms, " ")
	}

	## Every unordered pair of runs for every item.
	pairs : List(Item) -> List({ item : Item, a : (Str, Str), b : (Str, Str) })
	pairs = |items| {
		var $out = []
		for item in items {
			var $rest = item.translations
			for x in item.translations {
				$rest = $rest.drop_first(1)
				for y in $rest {
					$out = $out.append({ item, a: x, b: y })
				}
			}
		}
		$out
	}

	## A judge model's verdicts, stored in `out` so a repeated comparison costs nothing.
	judge! : List(Str), Str, Str, Bool => Try({}, [Failed(Str)])
	judge! = |dirs, judge_path, out, paid| {
		found = items!(dirs)?
		config = Io.json!(judge_path)?
		dir = Io.dir_of(judge_path)
		text = |key, default| (config.field(key) ?? JsonValue.str(default)).as_str() ?? default
		providers_path = Io.join(dir, text("providers", "providers.json"))
		providers = Provider.settings(Io.json!(providers_path)?).map_err(|m| Failed("${providers_path}: ${m}"))?
		model = Provider.model(config.field("model") ?? JsonValue.null, providers).map_err(|m| Failed("${judge_path}: ${m}"))?
		system = Io.read!(Io.join(dir, text("prompt", "prompts/judge.md")))?.trim()
		run = {
			experiment: "compare",
			label: model.name,
			model,
			steps: [],
			dataset: { name: "compare", title: "", input: "", format: Tokens, passages: BySentence, label_separator: ".", token_ids: Position, omitted_prefix: "", reference: "", limit: All, lines: AllLines },
			sentences: [],
			passages: [],
			reference: [],
			attempts: (config.field("attempts") ?? JsonValue.Number("2")).as_u64() ?? 2,
			timeout_seconds: (config.field("timeout_seconds") ?? JsonValue.Number("180")).as_u64() ?? 180,
			skip_failures: Bool.True,
			budget: (config.field("budget_usd") ?? JsonValue.Number("0")).as_dec() ?? 0,
			runs_dir: out,
			sources: [],
		}
		ctx = { run, dir: out, mode: Live({ paid: paid }), key: Io.key!(model) }
		max_tokens = (config.field("max_tokens") ?? JsonValue.Number("400")).as_u64() ?? 400
		var $outcomes = []
		var $lines = []
		var $spent = Execute.spent!(out)
		var $n = 0
		for p in pairs(found.items) {
			var $verdicts = []
			for (first, second) in [(p.a, p.b), (p.b, p.a)] {
				user = JsonValue.canonical(JsonValue.object([("greek", JsonValue.str(p.item.greek)), ("translation_a", JsonValue.str(first.1)), ("translation_b", JsonValue.str(second.1))]))
				match Execute.call!(ctx, $spent, "judge", $n, { system, user, max_tokens }, |content| verdict(Steps.reply_object(content)?)) {
					Ok(r) => {
						$spent = $spent + r.cost
						$verdicts = $verdicts.append(when(r.value, first.0, second.0))
					}
					Err(_) => {}
				}
			}
			verdicts = $verdicts
			$n = $n + 1
			outcome = match verdicts {
				[x, y] if x == y => x
				[_, _] => Tie(p.a.0, p.b.0)
				_ => Unjudged
			}
			match outcome {
				Unjudged => {}
				Win(w, l) => {
					$outcomes = $outcomes.append(Win(w, l))
					$lines = $lines.append(judgment(p.item.id, p.a.0, p.b.0, w))
				}
				Tie(a, b) => {
					$outcomes = $outcomes.append(Tie(a, b))
					$lines = $lines.append(judgment(p.item.id, a, b, "tie"))
				}
			}
		}
		Io.write!("${out}/judgments.jsonl", Str.join_with($lines.map(|l| "${JsonValue.encode(l)}\n"), ""))?
		report!(out, found.labels, $outcomes, [], "judge ${model.name}", $spent)
	}

	## `A`, `B` or `tie` from a judge's reply.
	verdict : JsonValue -> Try([A, B, Neither], Str)
	verdict = |reply| match (reply.field("winner") ?? JsonValue.str("")).as_str() ?? "" {
		"A" | "a" => Ok(A)
		"B" | "b" => Ok(B)
		"tie" | "TIE" | "Tie" => Ok(Neither)
		other => Err("winner must be A, B or tie, not ${other}")
	}

	when : [A, B, Neither], Str, Str -> [Win(Str, Str), Tie(Str, Str), Unjudged]
	when = |v, first, second| match v {
		A => Win(first, second)
		B => Win(second, first)
		Neither => Tie(first, second)
	}

	judgment : Str, Str, Str, Str -> JsonValue
	judgment = |item, a, b, winner| JsonValue.object([("item", JsonValue.str(item)), ("a", JsonValue.str(a)), ("b", JsonValue.str(b)), ("winner", JsonValue.str(winner))])

	## A blinded preference sheet (TSV) for reviewers, and its key: which run is A and which is B in each row.
	export_preferences! : List(Str), Str => Try({}, [Failed(Str)])
	export_preferences! = |dirs, sheet| {
		found = items!(dirs)?
		var $rows = ["row\titem\tgreek\tA\tB\tpreference (A, B or tie)"]
		var $key = []
		var $n = 1
		for p in pairs(found.items) {
			# Which run is shown first alternates, so position carries no information about the run.
			(first, second) = if $n % 2 == 0 (p.b, p.a) else (p.a, p.b)
			$rows = $rows.append(Str.join_with([$n.to_str(), p.item.id, cell(p.item.greek), cell(first.1), cell(second.1), ""], "\t"))
			$key = $key.append(JsonValue.object([("row", JsonValue.u64($n)), ("item", JsonValue.str(p.item.id)), ("A", JsonValue.str(first.0)), ("B", JsonValue.str(second.0))]))
			$n = $n + 1
		}
		Io.write!(sheet, "${Str.join_with($rows, "\n")}\n")?
		Io.write!("${sheet}.key.json", JsonValue.pretty(JsonValue.object([("runs", JsonValue.strs(found.labels)), ("rows", JsonValue.list($key))])))?
		Stdout.line!("wrote ${($n - 1).to_str()} pairs to ${sheet}; keep ${sheet}.key.json from reviewers").map_err(|_| Failed("stdout"))
	}

	cell : Str -> Str
	cell = |s| s.replace_each("\t", " ").replace_each("\n", " ")

	## Filled preference sheets (one per reviewer, all exported with the same key): a ranking, and agreement between
	## reviewers over the rows two or more of them labelled.
	import_preferences! : List(Str), Str, Str => Try({}, [Failed(Str)])
	import_preferences! = |sheets, key_path, out| {
		key = Io.json!(key_path)?
		rows = (key.field("rows") ?? JsonValue.list([])).items()
		labels = (key.field("runs") ?? JsonValue.list([])).items().map(|r| r.as_str() ?? "")
		var $outcomes = []
		var $per_row = rows.map(|_| [])
		for sheet in sheets {
			for line in Io.read!(sheet)?.split_on("\n").drop_first(1) {
				match line.split_on("\t") {
					[row, _, _, _, _, preference, ..] => {
						n = U64.from_str(row) ?? 0
						k = rows.get(n - 1) ?? JsonValue.null
						a = (k.field("A") ?? JsonValue.str("")).as_str() ?? ""
						b = (k.field("B") ?? JsonValue.str("")).as_str() ?? ""
						label = preference.trim()
						# A row's label for agreement names the winning run, so it is comparable across sheets.
						named = match label {
							"A" | "a" => Ok(a)
							"B" | "b" => Ok(b)
							"tie" | "Tie" | "TIE" => Ok("tie")
							_ => Err(Unlabelled)
						}
						match named {
							Ok(winner) => {
								$outcomes = $outcomes.append(if winner == "tie" Tie(a, b) else Win(winner, if winner == a b else a))
								$per_row = $per_row.set(n - 1, ($per_row.get(n - 1) ?? []).append(winner)) ?? $per_row
							}
							Err(_) => {}
						}
					}
					_ => {}
				}
			}
		}
		report!(out, labels, $outcomes, $per_row, "${sheets.len().to_str()} reviewer sheet(s)", 0)
	}

	## Rankings and counts, printed and written to `out/ranking.json`.
	report! : Str, List(Str), List(Metrics.Outcome), List(List(Str)), Str, Dec => Try({}, [Failed(Str)])
	report! = |out, labels, outcomes, per_row, source, spent| {
		ranking = Metrics.bradley_terry(outcomes)
		alpha = if per_row.any(|r| r.len() >= 2) Ok(Metrics.krippendorff_alpha(per_row)) else Err(OneRater)
		record = |label| {
			wins = outcomes.keep_if(|o| match o {
				Win(w, _) => w == label
				_ => Bool.False
			}).len()
			losses = outcomes.keep_if(|o| match o {
				Win(_, l) => l == label
				_ => Bool.False
			}).len()
			ties = outcomes.keep_if(|o| match o {
				Tie(a, b) => a == label or b == label
				_ => Bool.False
			}).len()
			(wins, losses, ties)
		}
		rows = ranking.map(|(label, strength)| {
			(w, l, t) = record(label)
			JsonValue.object([("run", JsonValue.str(label)), ("strength", JsonValue.dec(strength)), ("wins", JsonValue.u64(w)), ("losses", JsonValue.u64(l)), ("ties", JsonValue.u64(t))])
		})
		agreement = match alpha {
			Ok(a) => [("krippendorff_alpha", JsonValue.dec(a))]
			Err(_) => []
		}
		Io.write!("${out}/ranking.json", JsonValue.pretty(JsonValue.object([("source", JsonValue.str(source)), ("runs", JsonValue.strs(labels)), ("comparisons", JsonValue.u64(outcomes.len())), ("cost_usd", JsonValue.dec(spent)), ("ranking", JsonValue.list(rows))].concat(agreement))))?
		_ = Stdout.line!("${outcomes.len().to_str()} comparison(s) from ${source}; Bradley–Terry ranking:")
		for (label, strength) in ranking {
			(w, l, t) = record(label)
			_ = Stdout.line!("  ${label}: ${Execute.money(strength)} (won ${w.to_str()}, lost ${l.to_str()}, tied ${t.to_str()})")
		}
		_ = match alpha {
			Ok(a) => Stdout.line!("  agreement between reviewers (Krippendorff's alpha): ${Execute.money(a)}")
			Err(_) => Ok({})
		}
		Ok({})
	}

	## An MQM annotation sheet: one row per run translation, with columns for reviewers to list errors.
	export_mqm! : List(Str), Str => Try({}, [Failed(Str)])
	export_mqm! = |dirs, sheet| {
		found = items!(dirs)?
		var $rows = ["row\titem\tgreek\ttranslation\terrors (span | category | minor, major or critical; separate errors with ;;)"]
		var $key = []
		var $n = 1
		for item in found.items {
			for (label, translation) in item.translations {
				$rows = $rows.append(Str.join_with([$n.to_str(), item.id, cell(item.greek), cell(translation), ""], "\t"))
				$key = $key.append(JsonValue.object([("row", JsonValue.u64($n)), ("run", JsonValue.str(label)), ("words", JsonValue.u64(item.greek.split_on(" ").len()))]))
				$n = $n + 1
			}
		}
		Io.write!(sheet, "${Str.join_with($rows, "\n")}\n")?
		Io.write!("${sheet}.key.json", JsonValue.pretty(JsonValue.object([("rows", JsonValue.list($key))])))?
		Stdout.line!("wrote ${($n - 1).to_str()} translations to ${sheet}").map_err(|_| Failed("stdout"))
	}

	## MQM penalty per 100 source words for each run, from a filled sheet.
	import_mqm! : Str, Str => Try({}, [Failed(Str)])
	import_mqm! = |sheet, key_path| {
		rows = (Io.json!(key_path)?.field("rows") ?? JsonValue.list([])).items()
		var $runs = []
		for line in Io.read!(sheet)?.split_on("\n").drop_first(1) {
			match line.split_on("\t") {
				[row, _, _, _, errors, ..] => {
					k = rows.get((U64.from_str(row) ?? 0) - 1) ?? JsonValue.null
					run = (k.field("run") ?? JsonValue.str("")).as_str() ?? ""
					words = (k.field("words") ?? JsonValue.Number("0")).as_u64() ?? 0
					severities = errors.split_on(";;").keep_oks(|e| match e.split_on("|").map(|f| f.trim()) {
						[_, _, severity] => Ok(severity)
						_ => Err(NotAnError)
					})
					$runs = match $runs.find_first_index(|(r, _, _)| r == run) {
						Ok(i) => $runs.set(i, ((($runs.get(i) ?? (run, [], 0)).0), (($runs.get(i) ?? (run, [], 0)).1).concat(severities), (($runs.get(i) ?? (run, [], 0)).2) + words)) ?? $runs
						Err(_) => $runs.append((run, severities, words))
					}
				}
				_ => {}
			}
		}
		for (run, severities, words) in $runs {
			_ = Stdout.line!("  ${run}: MQM ${Execute.money(Metrics.mqm(severities, words))} per 100 source words (${severities.len().to_str()} error(s) over ${words.to_str()} words)")
		}
		Ok({})
	}
}
