## CoNLL-U sentences: comment lines and ten-column rows, kept as written so a file round-trips byte for byte
## through `parse` and `serialize` (apart from line endings and blank lines between sentences).
Conllu :: [].{
	Row : { id : Str, form : Str, lemma : Str, upos : Str, xpos : Str, feats : Str, head : Str, deprel : Str, deps : Str, misc : Str }

	## `line` is the 1-based line of the sentence's first line in its file.
	Sentence : { line : U64, comments : List(Str), rows : List(Row) }

	## Sentences, or the first line that is neither a comment nor ten tab-separated columns.
	parse : Str -> Try(List(Sentence), { line : U64, message : Str })
	parse = |text| {
		var $out = []
		for block in blocks(text) {
			var $comments = []
			var $rows = []
			var $n = block.line
			for line in block.lines {
				if line.starts_with("#") {
					$comments = $comments.append(line)
				} else {
					match line.split_on("\t") {
						[id, form, lemma, upos, xpos, feats, head, deprel, deps, misc] => {
							$rows = $rows.append({ id, form, lemma, upos, xpos, feats, head, deprel, deps, misc })
						}
						columns => return Err({ line: $n, message: "expected 10 tab-separated columns, found ${columns.len().to_str()}" })
					}
				}
				$n = $n + 1
			}
			$out = $out.append({ line: block.line, comments: $comments, rows: $rows })
		}
		Ok($out)
	}

	## Sentences separated by one blank line, the file ending with a newline after the last sentence's blank line.
	serialize : List(Sentence) -> Str
	serialize = |sentences| Str.join_with(sentences.map(|s| "${Str.join_with(sentence_lines(s), "\n")}\n\n"), "")

	sentence_lines : Sentence -> List(Str)
	sentence_lines = |s| s.comments.concat(s.rows.map(row_line))

	row_line : Row -> Str
	row_line = |r| Str.join_with([r.id, r.form, r.lemma, r.upos, r.xpos, r.feats, r.head, r.deprel, r.deps, r.misc], "\t")

	## Blank-line separated blocks with their first line number. Lines keep their text; `\r\n` becomes `\n`.
	blocks : Str -> List({ line : U64, lines : List(Str) })
	blocks = |text| {
		var $out = []
		var $current = []
		var $start = 1
		var $n = 1
		for line in text.replace_each("\r\n", "\n").split_on("\n") {
			if line.trim() == "" {
				if !$current.is_empty() {
					$out = $out.append({ line: $start, lines: $current })
					$current = []
				}
			} else {
				if $current.is_empty() {
					$start = $n
				}
				$current = $current.append(line)
			}
			$n = $n + 1
		}
		if ($current.is_empty()) $out else $out.append({ line: $start, lines: $current })
	}

	## The value of a `# key = value` comment.
	comment : Sentence, Str -> Try(Str, [Missing])
	comment = |s, key| {
		prefix = "# ${key} = "
		match s.comments.keep_if(|c| c.starts_with(prefix)) {
			[c, ..] => Ok(c.drop_prefix(prefix))
			[] => if (s.comments.contains("# ${key} =")) Ok("") else Err(Missing)
		}
	}

	## Sets `# key = value`, replacing the comment if present, otherwise appending it.
	set_comment : Sentence, Str, Str -> Sentence
	set_comment = |s, key, value| {
		prefix = "# ${key} ="
		line = "# ${key} = ${value}"
		if s.comments.any(|c| c.starts_with(prefix)) {
			{ ..s, comments: s.comments.map(|c| if (c.starts_with(prefix)) line else c) }
		} else {
			{ ..s, comments: s.comments.append(line) }
		}
	}

	## A word row: an integer ID, not a multiword range (`1-2`) or an empty node (`1.1`).
	is_word : Row -> Bool
	is_word = |r| U64.from_str(r.id).is_ok()

	misc_items : Row -> List(Str)
	misc_items = |r| if (r.misc == "_") [] else r.misc.split_on("|")

	## The value of a `key=value` MISC item.
	misc : Row, Str -> Try(Str, [Missing])
	misc = |r, key| match misc_items(r).keep_if(|item| item.starts_with("${key}=")) {
		[item, ..] => Ok(item.drop_prefix("${key}="))
		[] => Err(Missing)
	}

	## Sets a `key=value` MISC item, replacing an existing one in place.
	set_misc : Row, Str, Str -> Row
	set_misc = |r, key, value| {
		items = misc_items(r)
		item = "${key}=${value}"
		next = if (items.any(|i| i.starts_with("${key}="))) items.map(|i| if (i.starts_with("${key}=")) item else i) else items.append(item)
		{ ..r, misc: Str.join_with(next, "|") }
	}

	## Removes every `key=…` MISC item.
	drop_misc : Row, Str -> Row
	drop_misc = |r, key| {
		kept = misc_items(r).keep_if(|i| !i.starts_with("${key}="))
		{ ..r, misc: if (kept.is_empty()) "_" else Str.join_with(kept, "|") }
	}

	## The sentence's surface text: the forms of its word rows, or of a range in place of the words it covers.
	text : Sentence -> Str
	text = |s| Str.join_with(s.rows.keep_if(is_word).map(|r| r.form), " ")
}

expect {
	input = "# sent_id = 1\n# text = a b\n1\ta\ta\tX\t_\t_\t0\troot\t_\t_\n2\tb\tb\tX\t_\t_\t1\tdep\t_\tgloss=bee\n\n"
	match Conllu.parse(input) {
		Ok(sentences) => Conllu.serialize(sentences) == input and sentences.map(|s| s.rows.len()) == [2]
		Err(_) => Bool.False
	}
}

expect Conllu.parse("1\ta\n").is_err()

expect {
	row = { id: "1", form: "a", lemma: "a", upos: "X", xpos: "_", feats: "_", head: "0", deprel: "root", deps: "_", misc: "t_1" }
	glossed = Conllu.set_misc(row, "gloss", "and")
	glossed.misc == "t_1|gloss=and" and Conllu.misc(glossed, "gloss") == Ok("and") and Conllu.drop_misc(glossed, "gloss").misc == "t_1"
}

expect {
	s = { line: 1, comments: ["# sent_id = 1"], rows: [] }
	Conllu.comment(Conllu.set_comment(s, "text", "x"), "text") == Ok("x") and Conllu.comment(s, "text") == Err(Missing)
}
