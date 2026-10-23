import Conllu
import JsonValue

## A dataset: input sentences, how their tokens are identified, which rows are omitted structure, how tokens group
## into passages, and an optional line-parallel reference translation (for alignment).
Dataset :: [].{
	Passage : { ref : Str, label : Str, tokens : List(Str) }

	Spec : {
		name : Str,
		title : Str,
		input : Str,
		format : [Conllu, Tokens],
		passages : [BySentence, Refs(Str), File(Str)],
		token_ids : [Position, MiscFirst],
		omitted_prefix : Str,
		reference : Str,
		limit : [All, First(U64)],
	}

	## A spec from dataset.json. Paths are returned as written; the caller resolves them against the file's folder.
	spec : JsonValue -> Try(Spec, Str)
	spec = |json| {
		text = |key, default| match json.field(key) {
			Ok(v) => v.as_str().map_err(|_| "${key} must be a string")
			Err(_) => Ok(default)
		}
		name = text("name", "")?
		input = text("input", "")?
		if name == "" or input == "" {
			return Err("a dataset needs a name and an input")
		}
		format = match text("format", "conllu")? {
			"conllu" => Conllu
			"tokens" => Tokens
			other => return Err("format must be conllu or tokens, not ${other}")
		}
		passages = match json.field("passages") {
			Err(_) => BySentence
			Ok(p) => match p.field("kind").map_ok(|k| k.as_str() ?? "") ?? "" {
				"sentence" => BySentence
				"refs" => Refs(p.field("path").map_ok(|v| v.as_str() ?? "") ?? "")
				"file" => File(p.field("path").map_ok(|v| v.as_str() ?? "") ?? "")
				other => return Err("passages.kind must be sentence, refs or file, not ${other}")
			}
		}
		token_ids = match text("token_ids", "position")? {
			"position" => Position
			"misc-first" => MiscFirst
			other => return Err("token_ids must be position or misc-first, not ${other}")
		}
		limit = match json.field("limit") {
			Ok(v) => First(v.as_u64().map_err(|_| "limit must be a passage count")?)
			Err(_) => All
		}
		Ok({ name, title: text("title", name)?, input, format, passages, token_ids, omitted_prefix: text("omitted_misc_prefix", "")?, reference: text("reference", "")?, limit })
	}

	## Whitespace-tokenized text, one sentence per line, as minimal CoNLL-U (forms only, flat under word 1... no tree).
	from_tokens : Str -> List(Conllu.Sentence)
	from_tokens = |text| {
		var $out = []
		var $line = 1
		for raw in text.replace_each("\r\n", "\n").split_on("\n") {
			forms = raw.split_on(" ").keep_if(|f| f != "")
			if !forms.is_empty() {
				var $rows = []
				for form in forms {
					$rows = $rows.append({ id: ($rows.len() + 1).to_str(), form, lemma: "_", upos: "_", xpos: "_", feats: "_", head: "_", deprel: "_", deps: "_", misc: "_" })
				}
				$out = $out.append({ line: $line, comments: ["# sent_id = ${($out.len() + 1).to_str()}"], rows: $rows })
			}
			$line = $line + 1
		}
		$out
	}

	## Omitted structure: rows a corpus marks as not overt tokens (e.g. OGA's elliptic nodes, MISC `e_…`).
	is_omitted : Spec, Conllu.Row -> Bool
	is_omitted = |s, row| !Conllu.is_word(row) or (s.omitted_prefix != "" and row.misc.starts_with(s.omitted_prefix))

	## A row's token ID: `<sentence>:<id>` by position, or the first MISC item (OGA's `t_N`).
	token_id : Spec, U64, Conllu.Row -> Str
	token_id = |s, sentence, row| match s.token_ids {
		Position => "${(sentence + 1).to_str()}:${row.id}"
		MiscFirst => Conllu.misc_items(row).first() ?? row.id
	}

	## The overt tokens of sentence `index`.
	tokens : Spec, U64, Conllu.Sentence -> List(Str)
	tokens = |s, index, sentence| sentence.rows.keep_if(|r| !is_omitted(s, r)).map(|r| token_id(s, index, r))

	## One passage per sentence, referenced by its position.
	by_sentence : Spec, List(Conllu.Sentence) -> List(Passage)
	by_sentence = |s, sentences| {
		var $out = []
		var $i = 0
		for sentence in sentences {
			ref = ($i + 1).to_str()
			$out = $out.append({ ref, label: ref, tokens: tokens(s, $i, sentence) })
			$i = $i + 1
		}
		$out
	}

	## Consecutive tokens with the same citation (TSV rows `token<TAB>ref`) form a passage; `_` in a ref reads as `.`.
	from_refs : Spec, Str, List(Conllu.Sentence) -> Try(List(Passage), Str)
	from_refs = |s, tsv, sentences| {
		var $refs = Dict.empty()
		for line in tsv.split_on("\n") {
			match line.trim().split_on("\t") {
				[token, ref] => {
					$refs = $refs.insert(token, ref.replace_each("_", "."))
				}
				_ => {}
			}
		}
		var $out = []
		var $i = 0
		for sentence in sentences {
			for token in tokens(s, $i, sentence) {
				ref = $refs.get(token) ?? return Err("token ${token} has no citation")
				$out = match $out.last() {
					Ok(open) if open.ref == ref => $out.drop_last(1).append({ ..open, tokens: open.tokens.append(token) })
					_ => $out.append({ ref, label: ref, tokens: [token] })
				}
			}
			$i = $i + 1
		}
		Ok($out)
	}

	## Passages listed in a JSON file: `[{ "ref", "label", "tokens": [...] }]`.
	from_file : JsonValue -> Try(List(Passage), Str)
	from_file = |json| {
		var $out = []
		for item in json.items() {
			ref = item.field("ref").map_ok(|v| v.as_str() ?? "") ?? ""
			label = item.field("label").map_ok(|v| v.as_str() ?? ref) ?? ref
			ids = (item.field("tokens") ?? JsonValue.list([])).items().map(|t| t.as_str() ?? "")
			if ref == "" or ids.is_empty() or ids.contains("") {
				return Err("every passage needs a ref and token IDs")
			}
			$out = $out.append({ ref, label, tokens: ids })
		}
		Ok($out)
	}

	## The passages a run covers.
	selected : Spec, List(Passage) -> List(Passage)
	selected = |s, all| match s.limit {
		All => all
		First(n) => all.take_first(n)
	}

	## How many leading sentences hold every token of the passages.
	sentences_needed : Spec, List(Conllu.Sentence), List(Passage) -> U64
	sentences_needed = |s, sentences, passages| {
		last = passages.last().map_ok(|p| p.tokens.last() ?? "") ?? ""
		var $i = 0
		for sentence in sentences {
			if tokens(s, $i, sentence).contains(last) {
				return $i + 1
			}
			$i = $i + 1
		}
		if last == "" 0 else sentences.len()
	}
}

oga = { name: "t", title: "t", input: "x", format: Conllu, passages: BySentence, token_ids: MiscFirst, omitted_prefix: "e_", reference: "", limit: All }

two = match Conllu.parse("1\ta\ta\tX\t_\t_\t0\troot\t_\tt_1\n2\tb\tb\tX\t_\t_\t1\tdep\t_\te_1\n3\tc\tc\tX\t_\t_\t1\tdep\t_\tt_2\n\n1\td\td\tX\t_\t_\t0\troot\t_\tt_3\n\n") {
	Ok(s) => s
	Err(_) => []
}

expect Dataset.by_sentence(oga, two).map(|p| p.tokens) == [["t_1", "t_2"], ["t_3"]]

expect Dataset.from_refs(oga, "t_1\t1_1\nt_2\t1_2\nt_3\t1_2\n", two).map_ok(|ps| ps.map(|p| (p.ref, p.tokens))) == Ok([("1.1", ["t_1"]), ("1.2", ["t_2", "t_3"])])

expect Dataset.sentences_needed(oga, two, [{ ref: "1", label: "1", tokens: ["t_1"] }]) == 1

expect Dataset.from_tokens("a b\n\nc\n").map(|s| s.rows.map(|r| r.form)) == [["a", "b"], ["c"]]

expect Dataset.token_id({ ..oga, token_ids: Position }, 1, { id: "4", form: "", lemma: "", upos: "", xpos: "", feats: "", head: "", deprel: "", deps: "", misc: "" }) == "2:4"
