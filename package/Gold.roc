import JsonValue
import Metrics

## External gold data: a manifest pins each file (URL, SHA-256) with its licence and citation, and a kind says how to
## read the files and what it measures. apo owns no gold data; `apo gold fetch` downloads and checks it.
##   alignment:  line-parallel tokenized `source` and `target` files and a `links` file of `i-jS` / `i-jP` pairs
##               (0-based; S sure, P possible), as the Ugarit gold standards are published.
##   glosses:    JSONL `{ "ref", "position", "form", "accepted": [...] }`: accepted glosses for the word at a
##               1-based position among a passage's words; or `berean-xml`, the Berean Interlinear glosses.
##   references: JSONL `{ "ref", "translations": [...] }`: reference translations of a passage.
Gold :: [].{
	File : { name : Str, url : Str, sha256 : Str }

	Manifest : { name : Str, kind : Str, format : Str, license : Str, citation : Str, book : Str, files : List(File) }

	manifest : JsonValue -> Try(Manifest, Str)
	manifest = |json| {
		text = |key| (json.field(key) ?? JsonValue.str("")).as_str() ?? ""
		var $files = []
		for (name, f) in (json.field("files") ?? JsonValue.object([])).fields() {
			url = (f.field("url") ?? JsonValue.str("")).as_str() ?? ""
			sha = (f.field("sha256") ?? JsonValue.str("")).as_str() ?? ""
			if url == "" or sha.to_utf8().len() != 64 {
				return Err("file ${name} needs a url and a sha256")
			}
			$files = $files.append({ name, url, sha256: sha })
		}
		if text("name") == "" or !["alignment", "glosses", "references"].contains(text("kind")) {
			return Err("a gold manifest needs a name and a kind: alignment, glosses or references")
		}
		if text("license") == "" {
			return Err("a gold manifest must state the data's licence")
		}
		Ok({ name: text("name"), kind: text("kind"), format: text("format"), license: text("license"), citation: text("citation"), book: text("book"), files: $files })
	}

	Sentence : { source : List(Str), target : List(Str), gold : Metrics.Gold }

	## Ugarit-style alignment gold: line i of each file is sentence i.
	alignment : Str, Str, Str -> Try(List(Sentence), Str)
	alignment = |source, target, links| {
		lines = |t| t.replace_each("\r\n", "\n").trim_end().split_on("\n")
		s = lines(source)
		t = lines(target)
		l = lines(links)
		if s.len() != t.len() or s.len() != l.len() {
			return Err("source, target and links have ${s.len().to_str()}, ${t.len().to_str()} and ${l.len().to_str()} lines")
		}
		var $out = []
		var $i = 0
		for line in s {
			gold = parse_links(l.get($i) ?? "").map_err(|e| "links line ${($i + 1).to_str()}: ${e}")?
			$out = $out.append({ source: tokens(line), target: tokens(t.get($i) ?? ""), gold })
			$i = $i + 1
		}
		Ok($out)
	}

	tokens : Str -> List(Str)
	tokens = |line| line.split_on(" ").keep_if(|w| w != "")

	parse_links : Str -> Try(Metrics.Gold, Str)
	parse_links = |line| {
		var $sure = []
		var $possible = []
		for item in tokens(line) {
			kind = if item.ends_with("S") Sure else if item.ends_with("P") Possible else return Err("link ${item} lacks S or P")
			match item.drop_suffix("S").drop_suffix("P").split_on("-") {
				[a, b] => {
					pair = (U64.from_str(a) ?? return Err("bad link ${item}"), U64.from_str(b) ?? return Err("bad link ${item}"))
					if kind == Sure {
						$sure = $sure.append(pair)
					} else {
						$possible = $possible.append(pair)
					}
				}
				_ => return Err("bad link ${item}")
			}
		}
		Ok({ sure: $sure, possible: $possible })
	}

	Gloss : { ref : Str, position : U64, form : Str, accepted : List(Str) }

	glosses_jsonl : Str -> Try(List(Gloss), Str)
	glosses_jsonl = |text| {
		var $out = []
		for line in text.split_on("\n") {
			if line.trim() != "" {
				j = JsonValue.decode(line)?
				$out = $out.append({
					ref: (j.field("ref") ?? JsonValue.str("")).as_str() ?? "",
					position: (j.field("position") ?? JsonValue.Number("0")).as_u64() ?? 0,
					form: (j.field("form") ?? JsonValue.str("")).as_str() ?? "",
					accepted: (j.field("accepted") ?? JsonValue.list([])).items().map(|a| a.as_str() ?? ""),
				})
			}
		}
		Ok($out)
	}

	## The Berean Interlinear glosses of one book (`osisId="Rom.1.1!3"`), as glosses keyed by `chapter.verse` and
	## the word's position in the verse.
	berean_xml : Str, Str -> List(Gloss)
	berean_xml = |text, book| {
		var $out = []
		for chunk in text.split_on("<w ").drop_first(1) {
			osis = between(chunk, "osisId=\"", "\"")
			if osis.starts_with("${book}.") {
				match osis.drop_prefix("${book}.").split_on("!") {
					[verse, position] => {
						$out = $out.append({ ref: verse, position: U64.from_str(position) ?? 0, form: between(chunk, "<greek>", "</greek>"), accepted: [unescape(between(chunk, "<gloss>", "</gloss>"))] })
					}
					_ => {}
				}
			}
		}
		$out
	}

	between : Str, Str, Str -> Str
	between = |text, start, end| match text.split_first(start) {
		Ok({ before: _, after }) => match after.split_first(end) {
			Ok({ before, after: _ }) => before
			Err(_) => ""
		}
		Err(_) => ""
	}

	unescape : Str -> Str
	unescape = |s| s.replace_each("&lt;", "<").replace_each("&gt;", ">").replace_each("&quot;", "\"").replace_each("&apos;", "'").replace_each("&amp;", "&")

	## Pairs (run word, gold word) by index within one passage: identical forms first, each gold word used once; then,
	## when both have the same number of words, the rest in order. Editions that differ in word order or wording
	## still pair the words they share.
	match_words : List(Str), List(Str) -> List((U64, U64))
	match_words = |mine, theirs| {
		var $pairs = []
		var $i = 0.U64
		for form in mine {
			var $j = 0.U64
			var $found = Bool.False
			for other in theirs {
				if !$found and other == form and !$pairs.any(|(_, used)| used == $j) {
					$pairs = $pairs.append(($i, $j))
					$found = Bool.True
				}
				$j = $j + 1
			}
			$i = $i + 1
		}
		if mine.len() != theirs.len() {
			return $pairs
		}
		var $rest_mine = []
		var $k = 0.U64
		for _ in mine {
			if !$pairs.any(|(m, _)| m == $k) {
				$rest_mine = $rest_mine.append($k)
			}
			$k = $k + 1
		}
		var $rest_theirs = []
		var $l = 0.U64
		for _ in theirs {
			if !$pairs.any(|(_, t)| t == $l) {
				$rest_theirs = $rest_theirs.append($l)
			}
			$l = $l + 1
		}
		$pairs.concat(List.map2($rest_mine, $rest_theirs, |a, b| (a, b))).sort_with(|(a, _), (b, _)| if a < b Before else if a > b After else Same)
	}

	Reference : { ref : Str, translations : List(Str) }

	references_jsonl : Str -> Try(List(Reference), Str)
	references_jsonl = |text| {
		var $out = []
		for line in text.split_on("\n") {
			if line.trim() != "" {
				j = JsonValue.decode(line)?
				$out = $out.append({ ref: (j.field("ref") ?? JsonValue.str("")).as_str() ?? "", translations: (j.field("translations") ?? JsonValue.list([])).items().map(|t| t.as_str() ?? "") })
			}
		}
		Ok($out)
	}
}

expect Gold.parse_links("0-0S 0-1S 2-3P") == Ok({ sure: [(0, 0), (0, 1)], possible: [(2, 3)] })

expect Gold.parse_links("0-0X").is_err()

expect Gold.alignment("a b\nc", "x y\nz", "0-0S 1-1P\n0-0S").map_ok(|ss| ss.map(|s| s.gold.sure.len())) == Ok([1, 1])

expect Gold.berean_xml("<root><verse><w word=\"1\" osisId=\"Rom.1.1!1\">\n<greek>Παῦλος</greek>\n<gloss>Paul</gloss></w><w osisId=\"Matt.1.1!1\"><greek>x</greek><gloss>y</gloss></w>", "Rom") == [{ ref: "1.1", position: 1, form: "Παῦλος", accepted: ["Paul"] }]

expect Gold.match_words(["ΠΑΥΛΟΣ", "δοῦλος", "Ἰησοῦ", "Χριστοῦ"], ["Παῦλος", "δοῦλος", "Χριστοῦ", "Ἰησοῦ"]) == [(0, 0), (1, 1), (2, 3), (3, 2)]

expect Gold.match_words(["a", "b", "c"], ["c", "a"]) == [(0, 1), (2, 0)]
