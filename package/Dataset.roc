import Conllu

## A work's sentences as apo reads them: how their tokens are identified, which rows are omitted structure, and how
## tokens group into citation passages.
Dataset :: [].{
	Passage : { ref : Str, label : Str, tokens : List(Str) }

	Spec : { title : Str, label_separator : Str, token_ids : [Position, MiscFirst], omitted_prefix : Str }

	## The conventions of a work's CoNLL-U. Opera Graeca Adnotata keeps a stable token ID (`t_N`) as the first MISC
	## item and marks the rows it inserts for elided words with `e_…`; other CoNLL-U is identified by position.
	detect : Str, List(Conllu.Sentence) -> Spec
	detect = |title, sentences| {
		first = sentences.first().map_ok(|s| s.rows.keep_if(Conllu.is_word)) ?? []
		oga = match first {
			[row, ..] => row.misc.starts_with("t_")
			[] => Bool.False
		}
		if oga {
			{ title, label_separator: ".", token_ids: MiscFirst, omitted_prefix: "e_" }
		} else {
			{ title, label_separator: ".", token_ids: Position, omitted_prefix: "" }
		}
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
					_ => $out.append({ ref, label: ref.replace_each(".", s.label_separator), tokens: [token] })
				}
			}
			$i = $i + 1
		}
		Ok($out)
	}
}

two = Conllu.parse("1\ta\ta\tX\t_\t_\t0\troot\t_\tt_1\n2\tb\tb\tX\t_\t_\t1\tdep\t_\te_1\n3\tc\tc\tX\t_\t_\t1\tdep\t_\tt_2\n\n1\td\td\tX\t_\t_\t0\troot\t_\tt_3\n\n") ?? []

oga = Dataset.detect("t", two)

expect oga.token_ids == MiscFirst and oga.omitted_prefix == "e_"

expect Dataset.detect("t", Conllu.parse("1\ta\ta\tX\t_\t_\t0\troot\t_\t_\n\n") ?? []).token_ids == Position

expect Dataset.tokens(oga, 0, two.first() ?? { line: 0, comments: [], rows: [] }) == ["t_1", "t_2"]

expect Dataset.from_refs(oga, "t_1\t1_1\nt_2\t1_2\nt_3\t1_2\n", two).map_ok(|ps| ps.map(|p| (p.ref, p.tokens))) == Ok([("1.1", ["t_1"]), ("1.2", ["t_2", "t_3"])])

expect Dataset.from_refs(oga, "t_1\t1_1\n", two).is_err()

expect Dataset.token_id({ ..oga, token_ids: Position }, 1, { id: "4", form: "", lemma: "", upos: "", xpos: "", feats: "", head: "", deprel: "", deps: "", misc: "" }) == "2:4"
