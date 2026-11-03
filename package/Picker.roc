## The interactive list `apo init` and `apo login` show: type to filter, arrows to move, Enter to choose. Pure: the CLI
## reads keys and draws what `view` returns.
Picker :: [].{
	Key : [Up, Down, Enter, Backspace, Cancel, Text(Str)]

	Item : { label : Str, value : Str }

	State : { query : Str, cursor : U64 }

	start : State
	start = { query: "", cursor: 0 }

	## The keys in a chunk of terminal input. Printable bytes stay together, so a paste is one `Text`.
	keys : List(U8) -> List(Key)
	keys = |bytes| {
		var $out = []
		var $text = []
		var $i = 0
		at = |n| bytes.get(n) ?? 0
		flush = |out, text| if (text.is_empty()) out else out.append(Text(Str.from_utf8(text) ?? ""))
		while $i < bytes.len() {
			b = at($i)
			escape = b == 27 and at($i + 1) == 91
			key = if (escape and at($i + 2) == 65) {
				Ok(Up)
			} else if (escape and at($i + 2) == 66) {
				Ok(Down)
			} else if (b == 13 or b == 10) {
				Ok(Enter)
			} else if (b == 127 or b == 8) {
				Ok(Backspace)
			} else if (b == 3 or (b == 27 and !escape)) {
				Ok(Cancel)
			} else {
				Err(NotAKey)
			}
			match key {
				Ok(k) => {
					$out = flush($out, $text).append(k)
					$text = []
				}
				Err(_) => if (b >= 32 and !escape) {
					$text = $text.append(b)
				}
			}
			$i = $i + (if (escape) 3 else 1)
		}
		flush($out, $text)
	}

	## The items whose label contains every word of the query, ignoring ASCII case.
	matches : List(Item), Str -> List(Item)
	matches = |items, query| {
		words = lower(query).split_on(" ").keep_if(|w| w != "")
		items.keep_if(|i| words.all(|w| lower(i.label).contains(w)))
	}

	lower : Str -> Str
	lower = |text| Str.from_utf8(text.to_utf8().map(|b| if (b >= 'A' and b <= 'Z') b + 32 else b)) ?? text

	## The state after a key that neither chooses nor cancels.
	update : State, List(Item), Key -> State
	update = |state, items, key| {
		count = matches(items, state.query).len()
		match key {
			Up => { ..state, cursor: if (state.cursor == 0) (if (count == 0) 0 else count - 1) else state.cursor - 1 }
			Down => { ..state, cursor: if (state.cursor + 1 >= count) 0 else state.cursor + 1 }
			Backspace => { query: drop_last(state.query), cursor: 0 }
			Text(t) => { query: "${state.query}${t}", cursor: 0 }
			Enter | Cancel => state
		}
	}

	## The text without its last character.
	drop_last : Str -> Str
	drop_last = |text| {
		bytes = text.to_utf8()
		var $n = bytes.len()
		while $n > 0 {
			$n = $n - 1
			if ((bytes.get($n) ?? 0) < 128) or ((bytes.get($n) ?? 0) >= 192) {
				return Str.from_utf8(bytes.take_first($n)) ?? ""
			}
		}
		""
	}

	## What Enter chooses: the highlighted item, else the typed text when `free_text` allows it.
	chosen : State, List(Item), Bool -> Try(Str, [Nothing])
	chosen = |state, items, free_text| match matches(items, state.query).get(state.cursor) {
		Ok(item) => Ok(item.value)
		Err(_) => if (free_text and state.query != "") Ok(state.query) else Err(Nothing)
	}

	## The lines to draw: the title and query, then a window of up to `height` matches around the cursor.
	view : Str, State, List(Item), U64, Bool -> List(Str)
	view = |title, state, items, height, free_text| {
		found = matches(items, state.query)
		first = if (state.cursor < height) 0 else state.cursor + 1 - height
		shown = found.drop_first(first).take_first(height)
		var $lines = ["${title}: ${state.query}"]
		var $i = first
		for item in shown {
			$lines = $lines.append(if ($i == state.cursor) "> ${item.label}" else "  ${item.label}")
			$i = $i + 1
		}
		if found.is_empty() {
			$lines = $lines.append(if (free_text and state.query != "") "  (Enter to use \"${state.query}\")" else "  (no matches)")
		} else if found.len() > height {
			$lines = $lines.append("  ${found.len().to_str()} matches; type to filter")
		}
		$lines
	}
}

items = [{ label: "Ollama (local)", value: "ollama" }, { label: "OpenRouter", value: "openrouter" }, { label: "OpenAI", value: "openai" }]

expect Picker.keys([27, 91, 65, 104, 105, 13]) == [Up, Text("hi"), Enter]

expect Picker.keys([3]) == [Cancel]

expect Picker.matches(items, "open").map(|i| i.value) == ["openrouter", "openai"]

expect Picker.matches(items, "LOCAL oll").map(|i| i.value) == ["ollama"]

expect Picker.update({ query: "", cursor: 0 }, items, Up).cursor == 2

expect Picker.update({ query: "", cursor: 2 }, items, Down).cursor == 0

expect Picker.update({ query: "ab", cursor: 1 }, items, Backspace) == { query: "a", cursor: 0 }

expect Picker.update({ query: "aλ", cursor: 0 }, items, Backspace).query == "a"

expect Picker.chosen({ query: "openr", cursor: 0 }, items, Bool.False) == Ok("openrouter")

expect Picker.chosen({ query: "qwen", cursor: 0 }, items, Bool.True) == Ok("qwen")

expect Picker.chosen({ query: "qwen", cursor: 0 }, items, Bool.False) == Err(Nothing)

expect Picker.view("Provider", { query: "", cursor: 1 }, items, 2, Bool.False) == ["Provider: ", "  Ollama (local)", "> OpenRouter", "  3 matches; type to filter"]
