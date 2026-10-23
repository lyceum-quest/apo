import Conllu
import Dataset
import JsonValue

## The step kinds. Each fixes what the model sees (a JSON payload sent as the user message; the configured prompt is
## the system message), the reply it must give, the checks the reply must pass, and how an accepted reply is merged.
## Models never write IDs, rows, or files: apo does.
Steps :: [].{
	Kind : [TranslateSentence, GlossTokens, TranslatePassage, Align]

	kind : Str -> Try(Kind, Str)
	kind = |name| match name {
		"translate-sentence" => Ok(TranslateSentence)
		"gloss-tokens" => Ok(GlossTokens)
		"translate-passage" => Ok(TranslatePassage)
		"align" => Ok(Align)
		other => Err("unknown step kind ${other}; expected translate-sentence, gloss-tokens, translate-passage or align")
	}

	name : Kind -> Str
	name = |k| match k {
		TranslateSentence => "translate-sentence"
		GlossTokens => "gloss-tokens"
		TranslatePassage => "translate-passage"
		Align => "align"
	}

	Translation : { prose : Str, literal : Str }

	row_json : Conllu.Row -> JsonValue
	row_json = |r| JsonValue.object([("deprel", JsonValue.str(r.deprel)), ("deps", JsonValue.str(r.deps)), ("feats", JsonValue.str(r.feats)), ("form", JsonValue.str(r.form)), ("head", JsonValue.str(r.head)), ("id", JsonValue.str(r.id)), ("lemma", JsonValue.str(r.lemma)), ("misc", JsonValue.str(r.misc)), ("upos", JsonValue.str(r.upos)), ("xpos", JsonValue.str(r.xpos))])

	## A sentence as the model sees it: its comments, its overt tokens, and its omitted rows (evidence of ellipsis only).
	sentence_input : Dataset.Spec, Conllu.Sentence -> JsonValue
	sentence_input = |spec, s| JsonValue.object([
		("context_comments", JsonValue.strs(s.comments)),
		("omitted_structure", JsonValue.list(s.rows.keep_if(|r| Dataset.is_omitted(spec, r)).map(row_json))),
		("tokens", JsonValue.list(s.rows.keep_if(|r| !Dataset.is_omitted(spec, r)).map(row_json))),
	])

	gloss_contract = "Return a JSON object with a glosses array of {id, gloss} objects. Return exactly one object for each allowed_token_ids entry, including punctuation. The IDs are strings and may have gaps. Do not fill gaps or return any other IDs. Only tokens listed here may receive glosses."

	gloss_input : Dataset.Spec, Conllu.Sentence -> JsonValue
	gloss_input = |spec, s| {
		overt = s.rows.keep_if(|r| !Dataset.is_omitted(spec, r))
		JsonValue.object([
			("request_protocol", JsonValue.str("real-tokens-only-v2")),
			("context_comments", JsonValue.strs(s.comments)),
			("tokens", JsonValue.list(overt.map(row_json))),
			("allowed_token_ids", JsonValue.strs(overt.map(|r| r.id))),
			("output_contract", JsonValue.str(gloss_contract)),
		])
	}

	## A passage as the model sees it: its rows (glosses removed, so their style doesn't leak into translations), the
	## passage label, and each sentence it touches with that sentence's translations, for context.
	passage_input : Dataset.Spec, List(Conllu.Sentence), Dataset.Passage -> JsonValue
	passage_input = |spec, sentences, passage| {
		var $comments = ["# passage = ${passage.label}"]
		var $rows = []
		var $i = 0
		for s in sentences {
			ids = Dataset.tokens(spec, $i, s)
			if ids.any(|t| passage.tokens.contains(t)) {
				$comments = $comments.concat([
					"# context_sentence_greek = ${Str.join_with(s.rows.keep_if(|r| !Dataset.is_omitted(spec, r)).map(|r| r.form), " ")}",
					"# context_sentence_translation = ${Conllu.comment(s, "prose_translation") ?? ""}",
					"# context_sentence_literal_translation = ${Conllu.comment(s, "literal_translation") ?? ""}",
				])
				$rows = $rows.concat(s.rows.keep_if(|r| !Dataset.is_omitted(spec, r) and passage.tokens.contains(Dataset.token_id(spec, $i, r))).map(|r| Conllu.drop_misc(r, "gloss")))
			}
			$i = $i + 1
		}
		JsonValue.object([("context_comments", JsonValue.strs($comments)), ("omitted_structure", JsonValue.list([])), ("tokens", JsonValue.list($rows.map(row_json)))])
	}

	## Source and target tokens, numbered from 0.
	align_input : List(Str), List(Str) -> JsonValue
	align_input = |source, target| {
		numbered = |forms| {
			var $out = []
			for form in forms {
				$out = $out.append(JsonValue.object([("index", JsonValue.u64($out.len())), ("form", JsonValue.str(form))]))
			}
			JsonValue.list($out)
		}
		JsonValue.object([("source_tokens", numbered(source)), ("target_tokens", numbered(target)), ("output_contract", JsonValue.str("Return a JSON object with a links array of [source_index, target_index] pairs, one per aligned token pair; leave unaligned tokens out."))])
	}

	## The JSON object in a reply, without Markdown fences or surrounding prose.
	reply_object : Str -> Try(JsonValue, Str)
	reply_object = |content| {
		bytes = content.to_utf8()
		start = bytes.find_first_index(|b| b == '{') ?? return Err("the reply has no JSON object")
		end = bytes.find_last_index(|b| b == '}') ?? return Err("the reply has no JSON object")
		if end < start {
			return Err("the reply has no JSON object")
		}
		text = Str.from_utf8(bytes.sublist({ start, len: end - start + 1 })) ?? return Err("the reply is not UTF-8")
		JsonValue.decode(text).map_err(|m| "the reply's JSON is invalid: ${m}")
	}

	single_line : Str -> Bool
	single_line = |text| text.trim() != "" and !text.contains("\t") and !text.contains("\n") and !text.contains("\r")

	check_translation : JsonValue -> Try(Translation, Str)
	check_translation = |reply| {
		prose = (reply.field("prose_translation") ?? JsonValue.null).as_str() ?? ""
		literal = (reply.field("literal_translation") ?? JsonValue.null).as_str() ?? ""
		if !single_line(prose) or !single_line(literal) {
			Err("prose_translation and literal_translation must be non-empty single lines")
		} else {
			Ok({ prose: prose.trim(), literal: literal.trim() })
		}
	}

	merge_translation : Conllu.Sentence, U64, Str, Translation -> Conllu.Sentence
	merge_translation = |s, index, lang, t|
		Conllu.set_comment(Conllu.set_comment(Conllu.set_comment(Conllu.set_comment(s, "sentence_id", (index + 1).to_str()), "translation_lang", lang), "prose_translation", t.prose), "literal_translation", t.literal)

	## One gloss per overt token ID, none for anything else; a gloss is one line without `|` or tabs, and is not just the
	## token's form copied (punctuation, by UPOS, may gloss as itself).
	check_glosses : Dataset.Spec, Conllu.Sentence, List(Str), JsonValue -> Try(List((Str, Str)), Str)
	check_glosses = |spec, s, punctuation, reply| {
		overt = s.rows.keep_if(|r| !Dataset.is_omitted(spec, r))
		var $out = []
		for item in (reply.field("glosses") ?? JsonValue.null).items() {
			id = (item.field("id") ?? JsonValue.null).as_str() ?? ""
			gloss = ((item.field("gloss") ?? JsonValue.null).as_str() ?? "").trim()
			if $out.any(|(seen, _)| seen == id) {
				return Err("gloss for ${id} repeated")
			}
			row = match overt.keep_if(|r| r.id == id) {
				[r, ..] => r
				[] => return Err("gloss for unknown token ${id}")
			}
			if !single_line(gloss) or gloss.contains("|") {
				return Err("gloss for ${id} must be one non-empty line without |")
			}
			if gloss == row.form and !punctuation.contains(row.upos) and !symbol(row.form) {
				return Err("gloss for ${id} copies the form ${row.form}")
			}
			$out = $out.append((id, gloss))
		}
		missing = overt.keep_if(|r| !$out.any(|(id, _)| id == r.id))
		match missing {
			[r, ..] => Err("no gloss for token ${r.id}")
			[] => Ok($out)
		}
	}

	## A form with no letters or digits (punctuation), which may gloss as itself.
	symbol : Str -> Bool
	symbol = |form| ["·", "·", "—", "–", "‘", "’", "“", "”", "«", "»", "…", ";", "᾽", "ʼ", "†"].contains(form) or form.to_utf8().all(|b| b < 128 and !((b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9')))

	merge_glosses : Conllu.Sentence, List((Str, Str)) -> Conllu.Sentence
	merge_glosses = |s, glosses| {
		rows = s.rows.map(|r| match glosses.keep_if(|(id, _)| id == r.id) {
			[(_, g), ..] => Conllu.set_misc(r, "gloss", g)
			[] => r
		})
		{ ..s, rows }
	}

	## A passage translation as a line of units.jsonl.
	unit : Dataset.Passage, Translation -> JsonValue
	unit = |p, t| JsonValue.object([("label", JsonValue.str(p.label)), ("literal", JsonValue.str(t.literal)), ("prose", JsonValue.str(t.prose)), ("ref", JsonValue.str(p.ref)), ("tokens", JsonValue.strs(p.tokens))])

	## Links as index pairs within both token lists; `[[s, t], ...]` or `[{ "source", "target" }, ...]`.
	check_links : JsonValue, U64, U64 -> Try(List((U64, U64)), Str)
	check_links = |reply, source_count, target_count| {
		var $out = []
		for link in (reply.field("links") ?? return Err("the reply has no links array")).items() {
			pair = match link.items() {
				[a, b] => (a.as_u64() ?? return Err("link indices must be integers"), b.as_u64() ?? return Err("link indices must be integers"))
				_ => (
					(link.field("source") ?? JsonValue.null).as_u64() ?? return Err("a link must be [source, target]"),
					(link.field("target") ?? JsonValue.null).as_u64() ?? return Err("a link must be [source, target]"),
				)
			}
			(s, t) = pair
			if s >= source_count or t >= target_count {
				return Err("link ${s.to_str()}-${t.to_str()} is outside the sentence")
			}
			if !$out.contains(pair) {
				$out = $out.append(pair)
			}
		}
		Ok($out)
	}
}

oga = { name: "t", title: "t", input: "x", format: Conllu, passages: BySentence, token_ids: MiscFirst, omitted_prefix: "e_", reference: "", limit: All, lines: AllLines }

first_sentence = |text| match Conllu.parse(text) {
	Ok([s, ..]) => s
	_ => { line: 0, comments: [], rows: [] }
}

sentence = first_sentence("# sent_id = 1\n1\tκαί\tκαί\tc\t_\t_\t0\tAuxY\t_\tt_1\n2\t[0]\t_\tv\t_\t_\t1\tPRED\t_\te_1\n3\t.\t.\tu\t_\t_\t1\tAuxK\t_\tt_2\n\n")

glosses_of = |text| Steps.check_glosses(oga, sentence, ["u", "PUNCT"], JsonValue.decode(text) ?? JsonValue.null)

expect glosses_of("{\"glosses\": [{\"id\": \"1\", \"gloss\": \"and\"}, {\"id\": \"3\", \"gloss\": \".\"}]}") == Ok([("1", "and"), ("3", ".")])

expect glosses_of("{\"glosses\": [{\"id\": \"1\", \"gloss\": \"and\"}]}") == Err("no gloss for token 3")

expect glosses_of("{\"glosses\": [{\"id\": \"1\", \"gloss\": \"καί\"}, {\"id\": \"3\", \"gloss\": \".\"}]}").is_err()

expect glosses_of("{\"glosses\": [{\"id\": \"2\", \"gloss\": \"is\"}, {\"id\": \"1\", \"gloss\": \"and\"}, {\"id\": \"3\", \"gloss\": \".\"}]}") == Err("gloss for unknown token 2")

expect Steps.reply_object("```json\n{\"a\": 1}\n```") == Ok(JsonValue.object([("a", JsonValue.Number("1"))]))

expect Steps.check_translation(JsonValue.object([("prose_translation", JsonValue.str("And.")), ("literal_translation", JsonValue.str(" And. "))])) == Ok({ prose: "And.", literal: "And." })

expect {
	merged = Steps.merge_glosses(Steps.merge_translation(sentence, 4, "en", { prose: "P", literal: "L" }), [("1", "and")])
	Conllu.comment(merged, "sentence_id") == Ok("5") and merged.rows.map(|r| r.misc) == ["t_1|gloss=and", "e_1", "t_2"]
}

expect Steps.check_links(JsonValue.decode("{\"links\": [[0, 1], {\"source\": 1, \"target\": 0}]}") ?? JsonValue.null, 2, 2) == Ok([(0, 1), (1, 0)])

expect Steps.check_links(JsonValue.decode("{\"links\": [[0, 5]]}") ?? JsonValue.null, 2, 2).is_err()

expect {
	input = Steps.passage_input(oga, [Steps.merge_translation(sentence, 0, "en", { prose: "And.", literal: "And." })], { ref: "1.1", label: "1:1", tokens: ["t_1"] })
	(input.field("tokens") ?? JsonValue.null).items().len() == 1
}

expect Steps.symbol("—") and Steps.symbol(",") and !Steps.symbol("καί")
