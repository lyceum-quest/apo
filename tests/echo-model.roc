# A deterministic stand-in model for whole-run tests, run through the `command` protocol: it answers each step kind
# with a well-formed reply built from the request (glosses `gloss-<form>`, translations naming the token count,
# alignment links pairing equal positions). Setting `options.flaw` to `copy` makes its first gloss copy the form.
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	apo: "../package/main.roc",
}

import pf.Stdin
import pf.Stdout
import apo.JsonValue

main! = |_args| {
	text = Str.from_utf8(Stdin.read_to_end!()?) ?? ""
	request = JsonValue.decode(text) ?? JsonValue.null
	user = JsonValue.decode((request.field("user") ?? JsonValue.null).as_str() ?? "") ?? JsonValue.null
	flaw = ((request.field("options") ?? JsonValue.null).field("flaw") ?? JsonValue.null).as_str() ?? ""
	tokens = (user.field("tokens") ?? JsonValue.list([])).items()
	form = |t| (t.field("form") ?? JsonValue.null).as_str() ?? ""
	content = if user.field("allowed_token_ids").is_ok() {
		var $glosses = []
		for t in tokens {
			gloss = if flaw == "copy" and $glosses.is_empty() form(t) else "gloss-${form(t)}"
			$glosses = $glosses.append(JsonValue.object([("id", t.field("id") ?? JsonValue.null), ("gloss", JsonValue.str(gloss))]))
		}
		JsonValue.object([("glosses", JsonValue.list($glosses))])
	} else if user.field("source_tokens").is_ok() {
		source_count = (user.field("source_tokens") ?? JsonValue.list([])).items().len()
		target_count = (user.field("target_tokens") ?? JsonValue.list([])).items().len()
		var $links = []
		var $i = 0
		while $i < source_count and $i < target_count {
			$links = $links.append(JsonValue.list([JsonValue.u64($i), JsonValue.u64($i)]))
			$i = $i + 1
		}
		JsonValue.object([("links", JsonValue.list($links))])
	} else {
		n = tokens.len().to_str()
		JsonValue.object([("prose_translation", JsonValue.str("A sentence of ${n} words.")), ("literal_translation", JsonValue.str("a sentence of ${n} words"))])
	}
	Stdout.line!(JsonValue.encode(JsonValue.object([("content", JsonValue.str("```json\n${JsonValue.encode(content)}\n```")), ("input_tokens", JsonValue.u64(text.to_utf8().len() // 4)), ("output_tokens", JsonValue.u64(10)), ("cost", JsonValue.Number("0.001"))])))
}
