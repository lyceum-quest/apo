## A JSON value: configuration, model requests and replies, and run records.
## Decoding is bounded (size and depth) and rejects duplicate keys and trailing input.
## `encode` keeps key order; `canonical` sorts keys, so equal values hash equally.
JsonValue := [
	Object(List((Str, JsonValue))),
	Array(List(JsonValue)),
	String(Str),
	Number(Str),
	Boolean(Bool),
	Null,
].{
	is_eq : _

	max_bytes : U64
	max_bytes = 67108864

	max_depth : U64
	max_depth = 64

	decode : Str -> Try(JsonValue, Str)
	decode = |text| {
		bytes = text.to_utf8()
		if bytes.len() > max_bytes {
			return Err("JSON exceeds 64 MiB")
		}
		parsed = value(bytes, skip(bytes, 0), 0)?
		end = skip(bytes, parsed.next)
		if end != bytes.len() {
			return Err("trailing data at byte ${end.to_str()}")
		}
		Ok(parsed.json)
	}

	encode : JsonValue -> Str
	encode = |json| match json {
		Object(fields) => "{${Str.join_with(fields.map(|(k, v)| "${quote(k)}:${encode(v)}"), ",")}}"
		Array(items) => "[${Str.join_with(items.map(encode), ",")}]"
		String(text) => quote(text)
		Number(text) => text
		Boolean(b) => if (b) "true" else "false"
		Null => "null"
	}

	## Encoded with every object's keys sorted, for hashing and stable files.
	canonical : JsonValue -> Str
	canonical = |json| encode(sorted(json))

	sorted : JsonValue -> JsonValue
	sorted = |json| match json {
		Object(fields) => Object(fields.map(|(k, v)| (k, sorted(v))).sort_with(|(a, _), (b, _)| compare(a, b)))
		Array(items) => Array(items.map(sorted))
		other => other
	}

	## Indented two spaces, keys in their given order, for files people read.
	pretty : JsonValue -> Str
	pretty = |json| "${indented(json, "")}\n"

	indented : JsonValue, Str -> Str
	indented = |json, pad| match json {
		Object([]) => "{}"
		Array([]) => "[]"
		Object(fields) => {
			inner = "${pad}  "
			items = fields.map(|(k, v)| "${inner}${quote(k)}: ${indented(v, inner)}")
			"{\n${Str.join_with(items, ",\n")}\n${pad}}"
		}
		Array(items) => if items.all(is_scalar) {
			"[${Str.join_with(items.map(encode), ", ")}]"
		} else {
			inner = "${pad}  "
			"[\n${Str.join_with(items.map(|v| "${inner}${indented(v, inner)}"), ",\n")}\n${pad}]"
		}
		other => encode(other)
	}

	is_scalar : JsonValue -> Bool
	is_scalar = |json| match json {
		Object(_) => Bool.False
		Array(_) => Bool.False
		_ => Bool.True
	}

	compare : Str, Str -> [Before, Same, After]
	compare = |a, b| compare_bytes(a.to_utf8(), b.to_utf8())

	compare_bytes : List(U8), List(U8) -> [Before, Same, After]
	compare_bytes = |a, b| match (a, b) {
		([], []) => Same
		([], _) => Before
		(_, []) => After
		([x, .. as xs], [y, .. as ys]) => if (x < y) Before else if (x > y) After else compare_bytes(xs, ys)
	}

	# Constructors and accessors.

	str : Str -> JsonValue
	str = |text| String(text)

	u64 : U64 -> JsonValue
	u64 = |n| Number(n.to_str())

	dec : Dec -> JsonValue
	dec = |n| Number(n.to_str())

	bool : Bool -> JsonValue
	bool = |b| Boolean(b)

	null : JsonValue
	null = Null

	list : List(JsonValue) -> JsonValue
	list = |items| Array(items)

	object : List((Str, JsonValue)) -> JsonValue
	object = |fields| Object(fields)

	strs : List(Str) -> JsonValue
	strs = |values| Array(values.map(|s| String(s)))

	field : JsonValue, Str -> Try(JsonValue, [Missing(Str)])
	field = |json, name| match json {
		Object(fields) => match fields.keep_if(|(k, _)| k == name) {
			[(_, v), ..] => Ok(v)
			[] => Err(Missing(name))
		}
		_ => Err(Missing(name))
	}

	fields : JsonValue -> List((Str, JsonValue))
	fields = |json| match json {
		Object(items) => items
		_ => []
	}

	items : JsonValue -> List(JsonValue)
	items = |json| match json {
		Array(values) => values
		_ => []
	}

	as_str : JsonValue -> Try(Str, [NotA(Str)])
	as_str = |json| match json {
		String(text) => Ok(text)
		_ => Err(NotA("string"))
	}

	as_u64 : JsonValue -> Try(U64, [NotA(Str)])
	as_u64 = |json| match json {
		Number(text) => U64.from_str(text).map_err(|_| NotA("non-negative integer"))
		_ => Err(NotA("non-negative integer"))
	}

	as_dec : JsonValue -> Try(Dec, [NotA(Str)])
	as_dec = |json| match json {
		Number(text) => Dec.from_str(text).map_err(|_| NotA("number"))
		_ => Err(NotA("number"))
	}

	as_bool : JsonValue -> Try(Bool, [NotA(Str)])
	as_bool = |json| match json {
		Boolean(b) => Ok(b)
		_ => Err(NotA("boolean"))
	}

	## The object with `name` set to `v`, replacing an existing field in place.
	set : JsonValue, Str, JsonValue -> JsonValue
	set = |json, name, v| match json {
		Object(present) => if present.any(|(k, _)| k == name) {
			Object(present.map(|(k, old)| if (k == name) (k, v) else (k, old)))
		} else {
			Object(present.append((name, v)))
		}
		_ => Object([(name, v)])
	}

	## `overlay` fields replace or extend `base` fields, recursively for objects.
	merge : JsonValue, JsonValue -> JsonValue
	merge = |base, overlay| match (base, overlay) {
		(Object(_), Object(extra)) => {
			var $out = base
			for (k, v) in extra {
				next = match field($out, k) {
					Ok(old) => merge(old, v)
					Err(_) => v
				}
				$out = set($out, k, next)
			}
			$out
		}
		_ => overlay
	}

	quote : Str -> Str
	quote = |text| {
		var $out = ['"']
		for byte in text.to_utf8() {
			$out = $out.concat(
				match byte {
					'"' => ['\\', '"']
					'\\' => ['\\', '\\']
					'\n' => ['\\', 'n']
					'\r' => ['\\', 'r']
					'\t' => ['\\', 't']
					_ => if byte < ' ' {
						hex = "0123456789abcdef".to_utf8()
						['\\', 'u', '0', '0', hex.get(byte.to_u64() // 16) ?? '0', hex.get(byte.to_u64() % 16) ?? '0']
					} else {
						[byte]
					}
				},
			)
		}
		Str.from_utf8($out.append('"')) ?? "\"\""
	}

	# Decoding.

	skip : List(U8), U64 -> U64
	skip = |bytes, at| match bytes.get(at) {
		Ok(' ') | Ok('\n') | Ok('\r') | Ok('\t') => skip(bytes, at + 1)
		_ => at
	}

	value : List(U8), U64, U64 -> Try({ json : JsonValue, next : U64 }, Str)
	value = |bytes, at, depth| {
		if depth > max_depth {
			return Err("JSON nested deeper than ${max_depth.to_str()}")
		}
		match bytes.get(at) {
			Ok('{') => object_body(bytes, skip(bytes, at + 1), depth + 1, [])
			Ok('[') => array_body(bytes, skip(bytes, at + 1), depth + 1, [])
			Ok('"') => {
				s = string(bytes, at + 1)?
				Ok({ json: String(s.text), next: s.next })
			}
			Ok('t') => literal(bytes, at, "true", Boolean(Bool.True))
			Ok('f') => literal(bytes, at, "false", Boolean(Bool.False))
			Ok('n') => literal(bytes, at, "null", Null)
			Ok(_) => number(bytes, at)
			Err(_) => Err("unexpected end of JSON")
		}
	}

	literal : List(U8), U64, Str, JsonValue -> Try({ json : JsonValue, next : U64 }, Str)
	literal = |bytes, at, word, json| {
		want = word.to_utf8()
		if bytes.sublist({ start: at, len: want.len() }) == want {
			Ok({ json, next: at + want.len() })
		} else {
			Err("invalid literal at byte ${at.to_str()}")
		}
	}

	number : List(U8), U64 -> Try({ json : JsonValue, next : U64 }, Str)
	number = |bytes, at| {
		var $end = at
		while bytes.get($end).map_ok(is_number_byte) == Ok(Bool.True) {
			$end = $end + 1
		}
		text = Str.from_utf8(bytes.sublist({ start: at, len: $end - at })) ?? ""
		if text == "" or Dec.from_str(text).is_err() and F64.from_str(text).is_err() {
			Err("invalid number at byte ${at.to_str()}")
		} else {
			Ok({ json: Number(text), next: $end })
		}
	}

	is_number_byte : U8 -> Bool
	is_number_byte = |b| (b >= '0' and b <= '9') or b == '-' or b == '+' or b == '.' or b == 'e' or b == 'E'

	object_body : List(U8), U64, U64, List((Str, JsonValue)) -> Try({ json : JsonValue, next : U64 }, Str)
	object_body = |bytes, at, depth, found| {
		if bytes.get(at) == Ok('}') and found.is_empty() {
			return Ok({ json: Object(found), next: at + 1 })
		}
		if bytes.get(at) != Ok('"') {
			return Err("expected a key at byte ${at.to_str()}")
		}
		key = string(bytes, at + 1)?
		if found.any(|(k, _)| k == key.text) {
			return Err("duplicate key \"${key.text}\"")
		}
		colon = skip(bytes, key.next)
		if bytes.get(colon) != Ok(':') {
			return Err("expected ':' at byte ${colon.to_str()}")
		}
		v = value(bytes, skip(bytes, colon + 1), depth)?
		next = skip(bytes, v.next)
		collected = found.append((key.text, v.json))
		match bytes.get(next) {
			Ok(',') => object_body(bytes, skip(bytes, next + 1), depth, collected)
			Ok('}') => Ok({ json: Object(collected), next: next + 1 })
			_ => Err("expected ',' or '}' at byte ${next.to_str()}")
		}
	}

	array_body : List(U8), U64, U64, List(JsonValue) -> Try({ json : JsonValue, next : U64 }, Str)
	array_body = |bytes, at, depth, found| {
		if bytes.get(at) == Ok(']') and found.is_empty() {
			return Ok({ json: Array(found), next: at + 1 })
		}
		v = value(bytes, at, depth)?
		next = skip(bytes, v.next)
		collected = found.append(v.json)
		match bytes.get(next) {
			Ok(',') => array_body(bytes, skip(bytes, next + 1), depth, collected)
			Ok(']') => Ok({ json: Array(collected), next: next + 1 })
			_ => Err("expected ',' or ']' at byte ${next.to_str()}")
		}
	}

	string : List(U8), U64 -> Try({ text : Str, next : U64 }, Str)
	string = |bytes, start| {
		var $out = []
		var $at = start
		while Bool.True {
			match bytes.get($at) {
				Err(_) => return Err("unterminated string")
				Ok('"') => {
					text = Str.from_utf8($out) ?? return Err("invalid UTF-8 in string")
					return Ok({ text, next: $at + 1 })
				}
				Ok('\\') => {
					match bytes.get($at + 1) {
						Ok('"') => {
							$out = $out.append('"')
						}
						Ok('\\') => {
							$out = $out.append('\\')
						}
						Ok('/') => {
							$out = $out.append('/')
						}
						Ok('b') => {
							$out = $out.append(8)
						}
						Ok('f') => {
							$out = $out.append(12)
						}
						Ok('n') => {
							$out = $out.append('\n')
						}
						Ok('r') => {
							$out = $out.append('\r')
						}
						Ok('t') => {
							$out = $out.append('\t')
						}
						Ok('u') => {
							first = hex4(bytes, $at + 2)?
							if first >= 0xD800 and first <= 0xDBFF {
								if bytes.get($at + 6) != Ok('\\') or bytes.get($at + 7) != Ok('u') {
									return Err("unpaired surrogate")
								}
								second = hex4(bytes, $at + 8)?
								point = 0x10000 + (first - 0xD800) * 0x400 + (second - 0xDC00)
								$out = $out.concat(utf8(point))
								$at = $at + 6
							} else {
								$out = $out.concat(utf8(first))
							}
							$at = $at + 4
						}
						_ => return Err("invalid escape at byte ${$at.to_str()}")
					}
					$at = $at + 2
				}
				Ok(byte) => {
					if byte < ' ' {
						return Err("control character in string at byte ${$at.to_str()}")
					}
					$out = $out.append(byte)
					$at = $at + 1
				}
			}
		}
	}

	hex4 : List(U8), U64 -> Try(U32, Str)
	hex4 = |bytes, at| {
		var $n = 0
		for byte in bytes.sublist({ start: at, len: 4 }) {
			d = if byte >= '0' and byte <= '9' {
				byte - '0'
			} else if byte >= 'a' and byte <= 'f' {
				byte - 'a' + 10
			} else if byte >= 'A' and byte <= 'F' {
				byte - 'A' + 10
			} else {
				return Err("invalid \\u escape")
			}
			$n = $n * 16 + d.to_u32()
		}
		if bytes.sublist({ start: at, len: 4 }).len() != 4 {
			return Err("short \\u escape")
		}
		Ok($n)
	}

	utf8 : U32 -> List(U8)
	utf8 = |cp| {
		if cp < 0x80 {
			[cp.to_u8_wrap()]
		} else if cp < 0x800 {
			[(0xC0 + cp // 64).to_u8_wrap(), (0x80 + cp % 64).to_u8_wrap()]
		} else if cp < 0x10000 {
			[(0xE0 + cp // 4096).to_u8_wrap(), (0x80 + (cp // 64) % 64).to_u8_wrap(), (0x80 + cp % 64).to_u8_wrap()]
		} else {
			[(0xF0 + cp // 262144).to_u8_wrap(), (0x80 + (cp // 4096) % 64).to_u8_wrap(), (0x80 + (cp // 64) % 64).to_u8_wrap(), (0x80 + cp % 64).to_u8_wrap()]
		}
	}
}

expect JsonValue.decode("{\"b\": [1, true, null], \"a\": \"x\\u00e9\\n\"}") == Ok(JsonValue.object([("b", JsonValue.list([JsonValue.Number("1"), JsonValue.bool(Bool.True), JsonValue.null])), ("a", JsonValue.str("xé\n"))]))

expect JsonValue.decode("{\"a\": 1, \"a\": 2}").is_err()

expect JsonValue.decode("[1] x").is_err()

expect JsonValue.canonical(JsonValue.object([("b", JsonValue.u64(2)), ("a", JsonValue.object([("d", JsonValue.null), ("c", JsonValue.str("\"q\""))]))])) == "{\"a\":{\"c\":\"\\\"q\\\"\",\"d\":null},\"b\":2}"

expect JsonValue.decode("\"\\ud83d\\ude00\"") == Ok(JsonValue.str("😀"))

expect JsonValue.merge(JsonValue.object([("a", JsonValue.u64(1)), ("o", JsonValue.object([("x", JsonValue.u64(1))]))]), JsonValue.object([("o", JsonValue.object([("y", JsonValue.u64(2))]))])) == JsonValue.object([("a", JsonValue.u64(1)), ("o", JsonValue.object([("x", JsonValue.u64(1)), ("y", JsonValue.u64(2))]))])
