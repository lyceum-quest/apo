## Scores. Every function is pure and works on plain data, so a metric can be checked against published examples.
Metrics :: [].{
	Links : List((U64, U64))

	## One sentence of gold alignment: Sure links, and Possible links (which include the Sure ones).
	Gold : { sure : Links, possible : Links }

	Alignment : { precision : Dec, recall : Dec, f1 : Dec, aer : Dec, predicted : U64, sure : U64, possible : U64, correct : U64, partial : U64, wrong : U64 }

	## Precision against Possible, recall against Sure, and the alignment error rate of Och and Ney (2003), summed over
	## sentences. Per source token: correct when its predicted targets equal its gold targets, partial when they share
	## one, wrong otherwise (as Nadel and Crane (2025) report them).
	alignment : List((Links, Gold)) -> Alignment
	alignment = |pairs| {
		var $a = 0
		var $s = 0
		var $p = 0
		var $as = 0
		var $ap = 0
		var $correct = 0
		var $partial = 0
		var $wrong = 0
		for (predicted, gold) in pairs {
			possible = union(gold.possible, gold.sure)
			$a = $a + predicted.len()
			$s = $s + gold.sure.len()
			$p = $p + possible.len()
			$as = $as + predicted.keep_if(|l| gold.sure.contains(l)).len()
			$ap = $ap + predicted.keep_if(|l| possible.contains(l)).len()
			for source in sources(predicted.concat(possible)) {
				mine = targets_of(predicted, source)
				theirs = targets_of(possible, source)
				if !mine.is_empty() and mine.len() == theirs.len() and mine.all(|t| theirs.contains(t)) {
					$correct = $correct + 1
				} else if mine.any(|t| theirs.contains(t)) {
					$partial = $partial + 1
				} else {
					$wrong = $wrong + 1
				}
			}
		}
		precision = ratio($ap, $a)
		recall = ratio($as, $s)
		{
			precision,
			recall,
			f1: if precision + recall == 0 0 else 2 * precision * recall / (precision + recall),
			aer: if $a + $s == 0 0 else 1 - ($as + $ap).to_dec() / ($a + $s).to_dec(),
			predicted: $a,
			sure: $s,
			possible: $p,
			correct: $correct,
			partial: $partial,
			wrong: $wrong,
		}
	}

	union : Links, Links -> Links
	union = |a, b| a.concat(b.keep_if(|l| !a.contains(l)))

	sources : Links -> List(U64)
	sources = |links| {
		var $out = []
		for (s, _) in links {
			if !$out.contains(s) {
				$out = $out.append(s)
			}
		}
		$out
	}

	targets_of : Links, U64 -> List(U64)
	targets_of = |links, source| links.keep_if(|(s, _)| s == source).map(|(_, t)| t)

	ratio : U64, U64 -> Dec
	ratio = |n, d| if d == 0 0 else n.to_dec() / d.to_dec()

	## Lowercase words without punctuation or bracketed insertions: `[the] Of-God,` reads as ["the", "of", "god"].
	words : Str -> List(Str)
	words = |text| {
		var $out = []
		var $word = []
		for b in text.to_utf8().append(' ') {
			if b == ' ' or b == '-' or b == '\t' or (b < 128 and !is_letter(b) and b != '\'') {
				if !$word.is_empty() {
					$out = $out.append(Str.from_utf8($word) ?? "")
					$word = []
				}
			} else {
				$word = $word.append(if b >= 'A' and b <= 'Z' b + 32 else b)
			}
		}
		$out
	}

	is_letter : U8 -> Bool
	is_letter = |b| (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9')

	stopwords : List(Str)
	stopwords = ["a", "an", "the", "of", "to", "and", "in", "on", "for", "by", "with", "be", "is", "was", "it", "that", "as", "at", "from", "'s"]

	content : Str -> List(Str)
	content = |text| words(text).keep_if(|w| !stopwords.contains(w))

	## A gloss agrees with a gold rendering when they share a content word, or are both only function words and equal.
	gloss_agrees : Str, List(Str) -> Bool
	gloss_agrees = |gloss, accepted| accepted.any(|a| {
		mine = content(gloss)
		theirs = content(a)
		if mine.is_empty() or theirs.is_empty() words(gloss) == words(a) else mine.any(|w| theirs.contains(w))
	})

	## Exact agreement after normalization (case, brackets, punctuation), against any accepted gloss.
	gloss_exact : Str, List(Str) -> Bool
	gloss_exact = |gloss, accepted| accepted.any(|a| words(a) == words(gloss))

	## chrF (Popović 2015): character n-grams of 1 to 6, whitespace removed, recall weighted by beta = 2; corpus
	## statistics summed over segments, each against its best-scoring reference.
	chrf : List((Str, List(Str))) -> Dec
	chrf = |segments| {
		var $matched = List.repeat(0, 6)
		var $hyp = List.repeat(0, 6)
		var $ref = List.repeat(0, 6)
		for (hypothesis, references) in segments {
			h = chars(hypothesis)
			var $best = { score: -1, stats: [] }
			for r in references {
				stats = ngram_stats(h, chars(r))
				score = chrf_of(stats)
				if score > $best.score {
					$best = { score, stats }
				}
			}
			var $n = 0
			for (m, hc, rc) in $best.stats {
				$matched = $matched.set($n, ($matched.get($n) ?? 0) + m) ?? $matched
				$hyp = $hyp.set($n, ($hyp.get($n) ?? 0) + hc) ?? $hyp
				$ref = $ref.set($n, ($ref.get($n) ?? 0) + rc) ?? $ref
				$n = $n + 1
			}
		}
		chrf_of(List.map3($matched, $hyp, $ref, |m, hc, rc| (m, hc, rc)))
	}

	chrf_of : List((U64, U64, U64)) -> Dec
	chrf_of = |stats| {
		valid = stats.keep_if(|(_, hc, rc)| hc > 0 and rc > 0)
		if valid.is_empty() {
			return 0
		}
		precision = valid.map(|(m, hc, _)| ratio(m, hc)).sum() / valid.len().to_dec()
		recall = valid.map(|(m, _, rc)| ratio(m, rc)).sum() / valid.len().to_dec()
		if precision + recall == 0 0 else 100 * 5 * precision * recall / (4 * precision + recall)
	}

	## Code points without whitespace, as strings.
	chars : Str -> List(Str)
	chars = |text| {
		var $out = []
		var $current = []
		for b in text.to_utf8() {
			if b < 128 or b >= 192 {
				if !$current.is_empty() {
					$out = $out.append(Str.from_utf8($current) ?? "")
				}
				$current = if b == ' ' or b == '\n' or b == '\t' [] else [b]
			} else {
				$current = $current.append(b)
			}
		}
		if $current.is_empty() $out else $out.append(Str.from_utf8($current) ?? "")
	}

	## For n = 1..6: (matched, hypothesis, reference) n-gram counts, matches clipped by reference counts.
	ngram_stats : List(Str), List(Str) -> List((U64, U64, U64))
	ngram_stats = |h, r| [1, 2, 3, 4, 5, 6].map(|n| {
		hg = counts(grams(h, n))
		rg = counts(grams(r, n))
		matched = hg.map(|(g, c)| smaller(c, rg.keep_if(|(x, _)| x == g).map(|(_, k)| k).first() ?? 0)).sum()
		(matched, hg.map(|(_, c)| c).sum(), rg.map(|(_, c)| c).sum())
	})

	smaller : U64, U64 -> U64
	smaller = |a, b| if a < b a else b

	grams : List(Str), U64 -> List(Str)
	grams = |cs, n| {
		var $out = []
		var $i = 0
		while $i + n <= cs.len() {
			$out = $out.append(Str.join_with(cs.sublist({ start: $i, len: n }), ""))
			$i = $i + 1
		}
		$out
	}

	counts : List(Str) -> List((Str, U64))
	counts = |items| {
		var $d = Dict.empty()
		for i in items {
			$d = $d.insert(i, ($d.get(i) ?? 0) + 1)
		}
		$d.to_list()
	}

	## Bradley–Terry strengths from pairwise outcomes (`winner`, `loser`, or a tie as `Tie(a, b)`), by Hunter's (2004)
	## minorization–maximization; a tie counts half a win to each. Strengths sum to the number of systems.
	Outcome : [Win(Str, Str), Tie(Str, Str)]

	bradley_terry : List(Outcome) -> List((Str, Dec))
	bradley_terry = |outcomes| {
		var $systems = []
		for o in outcomes {
			for s in match o {
				Win(a, b) => [a, b]
				Tie(a, b) => [a, b]
			} {
				if !$systems.contains(s) {
					$systems = $systems.append(s)
				}
			}
		}
		wins = |s| outcomes.map(|o| match o {
			Win(a, _) if a == s => 1.0
			Tie(a, b) if a == s or b == s => 0.5
			_ => 0.0
		}).sum()
		games = |s, t| outcomes.keep_if(|o| match o {
			Win(a, b) => (a == s and b == t) or (a == t and b == s)
			Tie(a, b) => (a == s and b == t) or (a == t and b == s)
		}).len().to_dec()
		count = $systems.len().to_dec()
		var $strength = $systems.map(|s| (s, 1.0))
		var $round = 0
		while $round < 200 {
			next = $strength.map(|(s, ps)| {
				denominator = $strength.keep_if(|(t, _)| t != s).map(|(t, pt)| if games(s, t) == 0 0 else games(s, t) / (ps + pt)).sum()
				(s, if denominator == 0 ps else (if wins(s) < 0.01 0.01 else wins(s)) / denominator)
			})
			total = next.map(|(_, p)| p).sum()
			$strength = next.map(|(s, p)| (s, p * count / total))
			$round = $round + 1
		}
		$strength.sort_with(|(_, a), (_, b)| if a > b Before else if a < b After else Same)
	}

	## Krippendorff's alpha for nominal labels: `units` are the labels raters gave each item (any number of raters,
	## missing ratings left out). 1 is perfect agreement, 0 is chance.
	krippendorff_alpha : List(List(Str)) -> Dec
	krippendorff_alpha = |units| {
		pairable = units.keep_if(|u| u.len() >= 2)
		n = pairable.map(|u| u.len()).sum().to_dec()
		if n <= 1 {
			return 0
		}
		var $observed = 0
		var $totals = []
		for u in pairable {
			m = u.len().to_dec()
			disagreeing = u.map(|a| u.keep_if(|b| b != a).len()).sum().to_dec()
			$observed = $observed + disagreeing / (m - 1)
			$totals = $totals.concat(u)
		}
		labels = counts($totals)
		expected = labels.map(|(a, na)| labels.keep_if(|(b, _)| b != a).map(|(_, nb)| na.to_dec() * nb.to_dec()).sum()).sum()
		if expected == 0 1 else 1 - (n - 1) * $observed / expected
	}

	## Cohen's kappa for two raters' labels of the same items.
	cohen_kappa : List((Str, Str)) -> Dec
	cohen_kappa = |pairs| {
		n = pairs.len().to_dec()
		if n == 0 {
			return 0
		}
		agree = pairs.keep_if(|(a, b)| a == b).len().to_dec() / n
		first = counts(pairs.map(|(a, _)| a))
		second = counts(pairs.map(|(_, b)| b))
		chance = first.map(|(l, c)| c.to_dec() / n * ((second.keep_if(|(x, _)| x == l).map(|(_, k)| k).first() ?? 0).to_dec() / n)).sum()
		if chance == 1 1 else (agree - chance) / (1 - chance)
	}

	## MQM penalty per 100 source words: minor 1, major 5, critical 10 (MQM-DQF weights).
	mqm : List(Str), U64 -> Dec
	mqm = |severities, source_words| {
		weight = |s| match s {
			"minor" => 1
			"major" => 5
			"critical" => 10
			_ => 0
		}
		if source_words == 0 0 else severities.map(weight).sum() * 100 / source_words.to_dec()
	}
}

expect {
	gold = { sure: [(0, 0), (1, 1)], possible: [(2, 2)] }
	a = Metrics.alignment([([(0, 0), (2, 2), (3, 3)], gold)])
	a.precision == 2.0 / 3.0 and a.recall == 0.5 and a.aer == 1.0 - 3.0 / 5.0 and a.correct == 2 and a.wrong == 2
}

expect Metrics.alignment([([(0, 0)], { sure: [(0, 0)], possible: [] })]).aer == 0

expect Metrics.words("[the] Book-of, God's") == ["the", "book", "of", "god's"]

expect Metrics.gloss_agrees("of-the-genealogy", ["of [the] genealogy"]) and !Metrics.gloss_agrees("book", ["genealogy"])

expect Metrics.chrf([("the cat sat", ["the cat sat"])]) == 100

expect Metrics.chrf([("abc", ["xyz"])]) == 0

expect {
	ranked = Metrics.bradley_terry([Win("a", "b"), Win("a", "b"), Win("a", "b"), Win("b", "a"), Tie("a", "b")])
	ranked.map(|(s, _)| s) == ["a", "b"]
}

expect Metrics.krippendorff_alpha([["x", "x"], ["y", "y"], ["x", "x"]]) == 1

expect Metrics.cohen_kappa([("x", "x"), ("y", "y"), ("x", "y"), ("y", "x")]) == 0

expect Metrics.mqm(["minor", "major"], 200) == 3
