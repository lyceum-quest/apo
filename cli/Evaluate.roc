# Gold sets and scoring: fetch a gold manifest's files into the cache (checked against their SHA-256), and score runs.
import pf.Env
import pf.Http
import http.Request

import apo.Conllu
import apo.Gold
import apo.JsonValue
import apo.Metrics

import Io

Evaluate :: [].{
	## The folder gold files are cached in: APO_CACHE, else ~/.cache/apo.
	cache! : () => Str
	cache! = || match Env.var_str!(Io.os("APO_CACHE")) {
		Ok(dir) if dir != "" => "${dir}/gold"
		_ => "${Env.var_str!(Io.os("HOME")) ?? "."}/.cache/apo/gold"
	}

	## Each file's local path, downloading it first if it isn't cached; every file is checked against its SHA-256.
	fetch! : Gold.Manifest => Try(List((Str, Str)), [Failed(Str)])
	fetch! = |manifest| {
		var $out = []
		for file in manifest.files {
			path = "${cache!()}/${file.sha256}"
			if !Io.exists!(path) {
				response = Http.send!(Request.from_method(GET).with_uri(file.url).with_timeout(TimeoutMilliseconds(300000)), { max_redirects: 5 }).map_err(|e| Failed("cannot download ${file.url}: ${Str.inspect(e)}"))?
				if response.status() != 200 {
					return Err(Failed("${file.url}: HTTP ${response.status().to_str()}"))
				}
				Io.write!(path, Str.from_utf8(response.body()) ?? return Err(Failed("${file.url} is not UTF-8")))?
			}
			digest = Io.sha256!(Io.read!(path)?)?
			if digest != file.sha256 {
				return Err(Failed("${path} has SHA-256 ${digest}, not the pinned ${file.sha256}; delete it to download again"))
			}
			$out = $out.append((file.name, path))
		}
		Ok($out)
	}

	read_file! : List((Str, Str)), Str => Try(Str, [Failed(Str)])
	read_file! = |files, name| match files.keep_if(|(n, _)| n == name) {
		[(_, path), ..] => Io.read!(path)
		[] => Err(Failed("the gold manifest has no ${name} file"))
	}

	## What a run produced, from its directory.
	Output : { label : Str, dataset : Str, first_line : U64, sentences : List(Conllu.Sentence), links : List(List((U64, U64))), passages : List({ ref : Str, tokens : List(Str) }), units : List({ ref : Str, prose : Str }), token_ids : Str }

	output! : Str => Try(Output, [Failed(Str)])
	output! = |dir| {
		manifest = Io.json!("${dir}/manifest.json")?
		dataset = manifest.field("dataset") ?? JsonValue.object([])
		name = (dataset.field("name") ?? JsonValue.str("")).as_str() ?? ""
		sentences = Conllu.parse(Io.read!("${dir}/output/${name}.conllu") ?? "").map_err(|e| Failed("${dir}: ${e.message}"))?
		jsonl! = |filename| (Io.read!("${dir}/output/${filename}") ?? "").split_on("\n").keep_oks(|l| JsonValue.decode(l))
		var $links = []
		for line in jsonl!("alignments.jsonl") {
			$links = $links.append((line.field("links") ?? JsonValue.list([])).items().map(|p| match p.items() {
				[a, b] => (a.as_u64() ?? 0, b.as_u64() ?? 0)
				_ => (0, 0)
			}))
		}
		Ok({
			label: (manifest.field("label") ?? JsonValue.str(dir)).as_str() ?? dir,
			dataset: name,
			first_line: (dataset.field("first_line") ?? JsonValue.Number("1")).as_u64() ?? 1,
			sentences,
			links: $links,
			passages: jsonl!("passages.jsonl").map(|p| { ref: (p.field("ref") ?? JsonValue.str("")).as_str() ?? "", tokens: (p.field("tokens") ?? JsonValue.list([])).items().map(|t| t.as_str() ?? "") }),
			units: jsonl!("units.jsonl").map(|u| { ref: (u.field("ref") ?? JsonValue.str("")).as_str() ?? "", prose: (u.field("prose") ?? JsonValue.str("")).as_str() ?? "" }),
			token_ids: (dataset.field("token_ids") ?? JsonValue.str("position")).as_str() ?? "position",
		})
	}

	## Scores for one run against a gold set, as named values; each also says how much of the run it covered.
	score! : Gold.Manifest, List((Str, Str)), Output => Try(List((Str, JsonValue)), [Failed(Str)])
	score! = |manifest, files, run| match manifest.kind {
		"alignment" => {
			gold = Gold.alignment(read_file!(files, "source")?, read_file!(files, "target")?, read_file!(files, "links")?).map_err(|e| Failed("${manifest.name}: ${e}"))?
			var $pairs = []
			var $mismatched = 0
			var $glossed = 0
			var $agreeing = 0
			var $i = 0
			for sentence in run.sentences {
				g = gold.get(run.first_line - 1 + $i) ?? { source: [], target: [], gold: { sure: [], possible: [] } }
				forms = sentence.rows.keep_if(Conllu.is_word).map(|r| r.form)
				if forms != g.source {
					$mismatched = $mismatched + 1
				} else {
					match run.links.get($i) {
						Ok(predicted) => {
							$pairs = $pairs.append((predicted, g.gold))
						}
						Err(_) => {}
					}
					var $j = 0
					for row in sentence.rows.keep_if(Conllu.is_word) {
						english = g.gold.sure.keep_if(|(s, _)| s == $j).map(|(_, t)| g.target.get(t) ?? "")
						match Conllu.misc(row, "gloss") {
							Ok(gloss) if !english.is_empty() => {
								$glossed = $glossed + 1
								if Metrics.gloss_agrees(gloss, [Str.join_with(english, " ")]) {
									$agreeing = $agreeing + 1
								}
							}
							_ => {}
						}
						$j = $j + 1
					}
				}
				$i = $i + 1
			}
			a = Metrics.alignment($pairs)
			alignment_scores = if $pairs.is_empty() [] else [
				("alignment_sentences", JsonValue.u64($pairs.len())),
				("precision", JsonValue.dec(a.precision)),
				("recall", JsonValue.dec(a.recall)),
				("f1", JsonValue.dec(a.f1)),
				("aer", JsonValue.dec(a.aer)),
				("tokens_correct", JsonValue.u64(a.correct)),
				("tokens_partial", JsonValue.u64(a.partial)),
				("tokens_wrong", JsonValue.u64(a.wrong)),
			]
			gloss_scores = if $glossed == 0 [] else [("glosses_scored", JsonValue.u64($glossed)), ("gloss_alignment_agreement", JsonValue.dec(Metrics.ratio($agreeing, $glossed)))]
			Ok([("sentences_skipped_text_mismatch", JsonValue.u64($mismatched))].concat(alignment_scores).concat(gloss_scores))
		}
		"glosses" => {
			gold = match manifest.format {
				"berean-xml" => Gold.berean_xml(read_file!(files, "glosses")?, manifest.book)
				_ => Gold.glosses_jsonl(read_file!(files, "glosses")?).map_err(|e| Failed("${manifest.name}: ${e}"))?
			}
			rows = run.sentences.map(|s| s.rows.keep_if(Conllu.is_word)).join()
			id_of = |r| if run.token_ids == "misc-first" (Conllu.misc_items(r).first() ?? "") else ""
			var $compared = 0
			var $skipped = 0
			var $words = 0
			var $agree = 0
			var $exact = 0
			for p in run.passages {
				words = p.tokens.keep_oks(|t| match rows.keep_if(|r| id_of(r) == t) {
					[r, ..] => if r.upos == "u" or r.upos == "PUNCT" or Metrics.words(r.form).is_empty() and r.form.to_utf8().len() <= 3 Err(Punctuation) else Ok(r)
					[] => Err(Missing)
				})
				expected = gold.keep_if(|g| g.ref == p.ref).sort_with(|a, b| if a.position < b.position Before else if a.position > b.position After else Same)
				paired = Gold.match_words(words.map(|r| r.form), expected.map(|g| g.form))
				if paired.is_empty() {
					$skipped = $skipped + 1
				} else {
					$compared = $compared + 1
					for (m, t) in paired {
						r = words.get(m) ?? { id: "", form: "", lemma: "", upos: "", xpos: "", feats: "", head: "", deprel: "", deps: "", misc: "" }
						accepted = (expected.get(t) ?? { ref: "", position: 0, form: "", accepted: [] }).accepted
						gloss = Conllu.misc(r, "gloss") ?? ""
						$words = $words + 1
						if Metrics.gloss_agrees(gloss, accepted) {
							$agree = $agree + 1
						}
						if Metrics.gloss_exact(gloss, accepted) {
							$exact = $exact + 1
						}
					}
				}
			}
			Ok([
				("passages_compared", JsonValue.u64($compared)),
				("passages_without_matching_words", JsonValue.u64($skipped)),
				("words_compared", JsonValue.u64($words)),
				("gloss_agreement", JsonValue.dec(Metrics.ratio($agree, $words))),
				("gloss_exact", JsonValue.dec(Metrics.ratio($exact, $words))),
			])
		}
		_ => {
			references = Gold.references_jsonl(read_file!(files, "references")?).map_err(|e| Failed("${manifest.name}: ${e}"))?
			segments = run.units.keep_oks(|u| match references.keep_if(|r| r.ref == u.ref) {
				[r, ..] => Ok((u.prose, r.translations))
				[] => Err(Missing)
			})
			Ok([("passages_scored", JsonValue.u64(segments.len())), ("chrf", JsonValue.dec(Metrics.chrf(segments)))])
		}
	}
}
