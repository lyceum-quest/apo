## Prompt templates: `{{name}}` is replaced by the named variable. An unknown name or an unclosed `{{` is an error, so
## a typo never reaches a model as literal braces.
Template :: [].{
	render : Str, List((Str, Str)) -> Try(Str, Str)
	render = |template, variables| {
		var $out = ""
		var $rest = template
		while Bool.True {
			match $rest.split_first("{{") {
				Err(_) => return Ok(Str.concat($out, $rest))
				Ok({ before, after }) => match after.split_first("}}") {
					Err(_) => return Err("unclosed {{ in template")
					Ok({ before: name, after: remaining }) => {
						key = name.trim()
						value = match variables.keep_if(|(k, _)| k == key) {
							[(_, v), ..] => v
							[] => return Err("unknown template variable {{${key}}}")
						}
						$out = "${$out}${before}${value}"
						$rest = remaining
					}
				}
			}
		}
	}

	## The variable names a template uses, in order of first use.
	names : Str -> List(Str)
	names = |template| {
		var $found = []
		for part in template.split_on("{{").drop_first(1) {
			match part.split_first("}}") {
				Ok({ before, after: _ }) => if !$found.contains(before.trim()) {
					$found = $found.append(before.trim())
				}
				Err(_) => {}
			}
		}
		$found
	}
}

expect Template.render("Gloss {{ work }} in {{lang}}; {{work}}.", [("work", "Crito"), ("lang", "English")]) == Ok("Gloss Crito in English; Crito.")

expect Template.render("{{missing}}", []) == Err("unknown template variable {{missing}}")

expect Template.render("a {{b", [("b", "x")]).is_err()

expect Template.names("{{a}} {{ b }} {{a}}") == ["a", "b"]
