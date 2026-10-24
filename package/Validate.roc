import Conllu
import JsonValue

## CoNLL-U validation in two layers.
## Format: the label-independent rules of UD's levels 1 and 2 (ten columns, comments before rows, well-formed IDs,
## ranges and empty nodes, heads that form a rooted acyclic tree, FEATS/DEPS/MISC syntax, a final blank line).
## Profile: a JSON file of rules a corpus adds (required and unique comments, allowed UPOS and relations, one root,
## sorted features, required MISC keys). UD's own label rules are the `ud` profile in examples/profiles/.
Validate :: [].{
	Problem : { line : U64, code : Str, message : Str }

	Profile : {
		name : Str,
		required_comments : List(Str),
		unique_comments : List(Str),
		upos : List(Str),
		deprels : List(Str),
		single_root : Bool,
		root_deprel : Str,
		feats_sorted : Bool,
		misc_required : List(Str),
		misc_exempt_prefixes : List(Str),
	}

	no_profile : Profile
	no_profile = { name: "format", required_comments: [], unique_comments: [], upos: [], deprels: [], single_root: Bool.False, root_deprel: "", feats_sorted: Bool.False, misc_required: [], misc_exempt_prefixes: [] }

	## A profile from JSON; absent fields keep `no_profile`'s values (no rule).
	profile : JsonValue -> Try(Profile, Str)
	profile = |json| {
		strings = |key| match json.field(key) {
			Ok(v) => {
				var $out = []
				for item in v.items() {
					$out = $out.append(item.as_str().map_err(|_| "${key} must list strings")?)
				}
				Ok($out)
			}
			Err(_) => Ok([])
		}
		flag = |key| match json.field(key) {
			Ok(v) => v.as_bool().map_err(|_| "${key} must be true or false")
			Err(_) => Ok(Bool.False)
		}
		text = |key| match json.field(key) {
			Ok(v) => v.as_str().map_err(|_| "${key} must be a string")
			Err(_) => Ok("")
		}
		Ok({
			name: text("name")?,
			required_comments: strings("required_comments")?,
			unique_comments: strings("unique_comments")?,
			upos: strings("upos")?,
			deprels: strings("deprels")?,
			single_root: flag("single_root")?,
			root_deprel: text("root_deprel")?,
			feats_sorted: flag("feats_sorted")?,
			misc_required: strings("misc_required")?,
			misc_exempt_prefixes: strings("misc_exempt_prefixes")?,
		})
	}

	## Every problem in a file, in line order.
	check : Str, Profile -> List(Problem)
	check = |text, rules| {
		var $problems = []
		if text != "" and !text.replace_each("\r\n", "\n").ends_with("\n\n") {
			$problems = $problems.append({ line: line_count(text), code: "final-blank-line", message: "the file must end with a blank line after the last sentence" })
		}
		var $seen = []
		for block in Conllu.blocks(text) {
			result = sentence(block, rules)
			$problems = $problems.concat(result.problems)
			for key in rules.unique_comments {
				match block.lines.keep_if(|l| l.starts_with("# ${key} = ")) {
					[c, ..] => {
						if $seen.contains(c) {
							$problems = $problems.append({ line: block.line, code: "duplicate-comment", message: "duplicate ${c.drop_prefix("# ")}" })
						}
						$seen = $seen.append(c)
					}
					[] => {}
				}
			}
		}
		$problems
	}

	line_count : Str -> U64
	line_count = |text| text.split_on("\n").len()

	problem : U64, Str, Str -> Problem
	problem = |line, code, message| { line, code, message }

	sentence : { line : U64, lines : List(Str) }, Profile -> { problems : List(Problem) }
	sentence = |block, rules| {
		var $problems = []
		var $rows = []
		var $n = block.line
		var $in_rows = Bool.False
		for line in block.lines {
			if line.starts_with("#") {
				if $in_rows {
					$problems = $problems.append(problem($n, "comment-after-rows", "comments must precede a sentence's rows"))
				}
			} else {
				$in_rows = Bool.True
				match line.split_on("\t") {
					[id, form, lemma, upos, xpos, feats, head, deprel, deps, misc] => {
						row = { id, form, lemma, upos, xpos, feats, head, deprel, deps, misc }
						$problems = $problems.concat(fields($n, row))
						$rows = $rows.append({ line: $n, row })
					}
					columns => {
						$problems = $problems.append(problem($n, "columns", "expected 10 tab-separated columns, found ${columns.len().to_str()}"))
					}
				}
			}
			$n = $n + 1
		}
		if $rows.is_empty() {
			$problems = $problems.append(problem(block.line, "no-rows", "a sentence must have at least one row"))
			return { problems: $problems }
		}
		ids = identifiers($rows)
		$problems = $problems.concat(ids.problems)
		$problems = $problems.concat(tree($rows, ids.words, rules))
		$problems = $problems.concat(profile_rows($rows, rules))
		for key in rules.required_comments {
			if !block.lines.any(|l| l.starts_with("# ${key} = ") or l == "# ${key} =") {
				$problems = $problems.append(problem(block.line, "missing-comment", "missing # ${key} = …"))
			}
		}
		{ problems: $problems }
	}

	## No empty fields or edge whitespace; FEATS, DEPS and MISC syntax.
	fields : U64, Conllu.Row -> List(Problem)
	fields = |n, r| {
		var $out = []
		for value in [r.id, r.form, r.lemma, r.upos, r.xpos, r.feats, r.head, r.deprel, r.deps, r.misc] {
			if value == "" {
				$out = $out.append(problem(n, "empty-field", "empty column (use _)"))
			} else if value.trim() != value {
				$out = $out.append(problem(n, "field-whitespace", "a column begins or ends with whitespace"))
			}
		}
		if r.feats != "_" and !r.feats.split_on("|").all(
			|f| match f.split_on("=") {
				[k, v] => k != "" and v != ""
				_ => Bool.False
			},
		) {
			$out = $out.append(problem(n, "feats", "FEATS must be _ or Name=Value items separated by |"))
		}
		if r.deps != "_" and !r.deps.split_on("|").all(
			|d| match d.split_on(":") {
				[h, rel, ..] => h != "" and rel != ""
				_ => Bool.False
			},
		) {
			$out = $out.append(problem(n, "deps", "DEPS must be _ or head:relation items separated by |"))
		}
		if r.misc != "_" and r.misc.split_on("|").any(|m| m == "") {
			$out = $out.append(problem(n, "misc", "MISC must be _ or non-empty items separated by |"))
		}
		$out
	}

	## Words numbered 1..n; ranges a-b (a < b) start at the next word; empty nodes n.k follow word n, k from 1.
	identifiers : List({ line : U64, row : Conllu.Row }) -> { problems : List(Problem), words : U64 }
	identifiers = |rows| {
		var $problems = []
		var $word = 0
		var $empty = 0
		var $range_end = 0
		for { line, row } in rows {
			match row.id.split_on("-") {
				[a, b] => {
					match (U64.from_str(a), U64.from_str(b)) {
						(Ok(start), Ok(end)) => {
							if start != $word + 1 or end <= start {
								$problems = $problems.append(problem(line, "range-id", "range ${row.id} must start at word ${($word + 1).to_str()} and span at least two words"))
							} else if start <= $range_end {
								$problems = $problems.append(problem(line, "range-overlap", "range ${row.id} overlaps the previous range"))
							}
							$range_end = end
							if [row.lemma, row.upos, row.xpos, row.feats, row.head, row.deprel, row.deps].any(|v| v != "_") {
								$problems = $problems.append(problem(line, "range-columns", "a range row has _ in LEMMA through DEPS"))
							}
						}
						_ => {
							$problems = $problems.append(problem(line, "id", "invalid ID ${row.id}"))
						}
					}
				}
				_ => match row.id.split_on(".") {
					[w, k] => match (U64.from_str(w), U64.from_str(k)) {
						(Ok(after), Ok(index)) => {
							if after != $word or index != $empty + 1 {
								$problems = $problems.append(problem(line, "empty-id", "empty node ${row.id} must be ${$word.to_str()}.${($empty + 1).to_str()}"))
							}
							$empty = index
							if row.head != "_" or row.deprel != "_" {
								$problems = $problems.append(problem(line, "empty-columns", "an empty node has _ in HEAD and DEPREL"))
							}
						}
						_ => {
							$problems = $problems.append(problem(line, "id", "invalid ID ${row.id}"))
						}
					}
					_ => match U64.from_str(row.id) {
						Ok(id) => {
							if id != $word + 1 {
								$problems = $problems.append(problem(line, "word-id", "word ID ${row.id} must be ${($word + 1).to_str()}"))
							}
							$word = id
							$empty = 0
						}
						Err(_) => {
							$problems = $problems.append(problem(line, "id", "invalid ID ${row.id}"))
						}
					}
				}
			}
		}
		if $range_end > $word {
			$problems = $problems.append(problem(rows.first().map_ok(|r| r.line) ?? 0, "range-id", "a range ends after the last word"))
		}
		{ problems: $problems, words: $word }
	}

	## Every word's HEAD is 0..n and not itself; heads reach a root without cycles; at least one root.
	tree : List({ line : U64, row : Conllu.Row }), U64, Profile -> List(Problem)
	tree = |rows, count, rules| {
		words = rows.keep_if(|r| Conllu.is_word(r.row))
		var $problems = []
		var $heads = []
		for { line, row } in words {
			match U64.from_str(row.head) {
				Ok(h) => {
					if h > count {
						$problems = $problems.append(problem(line, "head-range", "HEAD ${row.head} is not a word of this sentence"))
					} else if row.head == row.id {
						$problems = $problems.append(problem(line, "head-self", "a word cannot be its own head"))
					}
					$heads = $heads.append(h)
				}
				Err(_) => {
					$problems = $problems.append(problem(line, "head", "HEAD must be a word number or 0"))
					$heads = $heads.append(0)
				}
			}
		}
		if !$problems.is_empty() {
			return $problems
		}
		roots = $heads.keep_if(|h| h == 0).len()
		first = words.first().map_ok(|r| r.line) ?? 0
		if roots == 0 {
			return $problems.append(problem(first, "no-root", "no word has HEAD 0"))
		} else if rules.single_root and roots > 1 {
			$problems = $problems.append(problem(first, "multiple-roots", "${roots.to_str()} words have HEAD 0"))
		}
		var $index = 0
		for h in $heads {
			if reaches_cycle($heads, $index + 1, 0, count) {
				line = words.get($index).map_ok(|r| r.line) ?? first
				return $problems.append(problem(line, "cycle", "word ${($index + 1).to_str()} is in a dependency cycle"))
			}
			_ = h
			$index = $index + 1
		}
		$problems
	}

	## Whether following heads from `word` loops instead of reaching 0.
	reaches_cycle : List(U64), U64, U64, U64 -> Bool
	reaches_cycle = |heads, word, steps, limit|
		if word == 0 {
			Bool.False
		} else if steps > limit {
			Bool.True
		} else {
			reaches_cycle(heads, heads.get(word - 1) ?? 0, steps + 1, limit)
		}

	profile_rows : List({ line : U64, row : Conllu.Row }), Profile -> List(Problem)
	profile_rows = |rows, rules| {
		var $out = []
		for { line, row } in rows {
			if Conllu.is_word(row) {
				if !rules.upos.is_empty() and !rules.upos.contains(row.upos) {
					$out = $out.append(problem(line, "upos", "UPOS ${row.upos} is not allowed"))
				}
				main = row.deprel.split_on(":").first() ?? row.deprel
				if !rules.deprels.is_empty() and !rules.deprels.contains(main) {
					$out = $out.append(problem(line, "deprel", "DEPREL ${row.deprel} is not allowed"))
				}
				if rules.root_deprel != "" and (row.head == "0") != (main == rules.root_deprel) {
					$out = $out.append(problem(line, "root-deprel", "DEPREL ${rules.root_deprel} goes with HEAD 0 and only there"))
				}
				if rules.feats_sorted and row.feats != "_" {
					names = row.feats.split_on("|").map(|f| f.split_on("=").first() ?? f)
					if !sorted_unique(names) {
						$out = $out.append(problem(line, "feats-order", "FEATS must be sorted by name without repeats"))
					}
				}
				exempt = rules.misc_exempt_prefixes.any(|p| row.misc.starts_with(p))
				if !exempt {
					for key in rules.misc_required {
						if Conllu.misc(row, key).is_err() {
							$out = $out.append(problem(line, "misc-required", "missing ${key}= in MISC"))
						}
					}
				}
			}
		}
		$out
	}

	## Case-insensitively ascending, as UD orders feature names.
	sorted_unique : List(Str) -> Bool
	sorted_unique = |names| match names {
		[a, b, .. as rest] => before(lower(a), lower(b)) and sorted_unique(rest.prepend(b))
		_ => Bool.True
	}

	lower : Str -> List(U8)
	lower = |s| s.to_utf8().map(|b| if (b >= 'A' and b <= 'Z') b + 32 else b)

	before : List(U8), List(U8) -> Bool
	before = |a, b| match (a, b) {
		([], []) => Bool.False
		([], _) => Bool.True
		(_, []) => Bool.False
		([x, .. as xs], [y, .. as ys]) => if (x == y) before(xs, ys) else x < y
	}
}

good = "# sent_id = 1\n1-2\tab\t_\t_\t_\t_\t_\t_\t_\t_\n1\ta\ta\tX\t_\tA=1|b=2\t0\troot\t_\t_\n2\tb\tb\tX\t_\t_\t1\tdep\t_\tgloss=x\n2.1\tc\tc\tX\t_\t_\t_\t_\t1:dep\t_\n\n"

codes = |text, rules| Validate.check(text, rules).map(|p| p.code)

expect codes(good, Validate.no_profile) == []

expect codes("1\ta\ta\tX\t_\t_\t2\tdep\t_\t_\n2\tb\tb\tX\t_\t_\t1\tdep\t_\t_\n\n", Validate.no_profile) == ["no-root"]

expect codes("1\ta\ta\tX\t_\t_\t0\troot\t_\t_\n3\tb\tb\tX\t_\t_\t1\tdep\t_\t_\n\n", Validate.no_profile) == ["word-id"]

expect codes("1\ta\ta\tX\t_\t_\t0\troot\t_\t_\n", Validate.no_profile) == ["final-blank-line"]

expect codes("1\ta\ta\tX\t_\t_\t0\troot\t_\t_\n# late\n\n", Validate.no_profile) == ["comment-after-rows"]

expect codes("1\ta\ta\tX\t_\t_\t0\troot\t_\t_\n2\tb\tb\tX\t_\t_\t3\tdep\t_\t_\n3\tc\tc\tX\t_\t_\t2\tdep\t_\t_\n\n", Validate.no_profile) == ["cycle"]

expect {
	rules = { ..Validate.no_profile, required_comments: ["text"], unique_comments: ["sent_id"], upos: ["NOUN"], root_deprel: "root", feats_sorted: Bool.True, misc_required: ["gloss"] }
	codes("${good}${good}", rules) == ["upos", "misc-required", "upos", "missing-comment", "upos", "misc-required", "upos", "missing-comment", "duplicate-comment"]
}
