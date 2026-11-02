import JsonValue
import Provider

## apo's configuration (`config.json`): providers, models, where works are read and outputs written, and limits.
## Every key is checked: an unknown key or a value of the wrong type is an error, so a typo never silently changes
## what a run does. Paths are returned as written; the caller resolves them against the file's folder.
Config :: [].{
	Limits : { attempts : U64, timeout_seconds : U64, translate_tokens : U64, gloss_tokens : U64, passage_tokens : U64 }

	## Per-work settings that cannot be read from the work's files.
	Work : { name : Str, label_separator : Str }

	Settings : { models : List(Provider.Model), works_dir : Str, output_dir : Str, prompts_dir : Str, limits : Limits, author : Str, works : List(Work) }

	default_limits : Limits
	default_limits = { attempts: 3, timeout_seconds: 180, translate_tokens: 1024, gloss_tokens: 2048, passage_tokens: 1024 }

	parse : JsonValue -> Try(Settings, Str)
	parse = |json| {
		known(json, "the configuration", ["providers", "models", "works_dir", "output_dir", "prompts_dir", "limits", "author", "works"])?
		var $providers = []
		for (name, p) in object(json, "providers")? {
			known(p, "provider ${name}", ["protocol", "base_url", "key_env", "headers", "command"])?
			$providers = $providers.append(Provider.settings(name, p)?)
		}
		var $models = []
		for m in (json.field("models") ?? JsonValue.list([])).items() {
			known(m, "a model", ["name", "provider", "id", "options"])?
			id = text(m, "id", "")?
			name = text(m, "name", id)?
			if id == "" {
				return Err("every model needs an id")
			}
			provider_name = text(m, "provider", "")?
			provider = match $providers.keep_if(|p| p.name == provider_name) {
				[p, ..] => p
				[] => return Err("model ${name}: no provider named \"${provider_name}\"")
			}
			if $models.any(|other| other.name == name) {
				return Err("two models are named ${name}")
			}
			$models = $models.append({ name, provider, id, options: m.field("options") ?? JsonValue.object([]) })
		}
		if $models.is_empty() {
			return Err("the configuration names no models")
		}
		limits_json = json.field("limits") ?? JsonValue.object([])
		known(limits_json, "limits", ["attempts", "timeout_seconds", "max_tokens"])?
		tokens_json = limits_json.field("max_tokens") ?? JsonValue.object([])
		known(tokens_json, "limits.max_tokens", ["translate", "gloss", "passage"])?
		d = default_limits
		limits = {
			attempts: count(limits_json, "attempts", d.attempts)?,
			timeout_seconds: count(limits_json, "timeout_seconds", d.timeout_seconds)?,
			translate_tokens: count(tokens_json, "translate", d.translate_tokens)?,
			gloss_tokens: count(tokens_json, "gloss", d.gloss_tokens)?,
			passage_tokens: count(tokens_json, "passage", d.passage_tokens)?,
		}
		if limits.attempts == 0 {
			return Err("limits.attempts must be at least 1")
		}
		author_json = json.field("author") ?? JsonValue.object([])
		known(author_json, "author", ["name", "email"])?
		author = match (text(author_json, "name", "")?, text(author_json, "email", "")?) {
			("", "") => ""
			(n, "") => n
			("", e) => "<${e}>"
			(n, e) => "${n} <${e}>"
		}
		var $works = []
		for (name, w) in object(json, "works")? {
			known(w, "works.${name}", ["label_separator"])?
			$works = $works.append({ name, label_separator: text(w, "label_separator", ".")? })
		}
		works_dir = text(json, "works_dir", "")?
		if works_dir == "" {
			return Err("the configuration needs works_dir")
		}
		Ok({ models: $models, works_dir, output_dir: text(json, "output_dir", "apo-output")?, prompts_dir: text(json, "prompts_dir", "")?, limits, author, works: $works })
	}

	## An error naming the first key of `json` outside `keys`.
	known : JsonValue, Str, List(Str) -> Try({}, Str)
	known = |json, what, keys| {
		fields = match json {
			JsonValue.Object(items) => items
			_ => return Err("${what} must be an object")
		}
		match fields.keep_if(|(k, _)| !keys.contains(k)) {
			[(k, _), ..] => Err("${what}: unknown key \"${k}\"; expected one of ${Str.join_with(keys, ", ")}")
			[] => Ok({})
		}
	}

	object : JsonValue, Str -> Try(List((Str, JsonValue)), Str)
	object = |json, key| match json.field(key) {
		Ok(v) => {
			known(v, key, v.fields().map(|(k, _)| k))?
			Ok(v.fields())
		}
		Err(_) => Ok([])
	}

	text : JsonValue, Str, Str -> Try(Str, Str)
	text = |json, key, default| match json.field(key) {
		Ok(v) => v.as_str().map_err(|_| "${key} must be a string")
		Err(_) => Ok(default)
	}

	count : JsonValue, Str, U64 -> Try(U64, Str)
	count = |json, key, default| match json.field(key) {
		Ok(v) => v.as_u64().map_err(|_| "${key} must be a whole number")
		Err(_) => Ok(default)
	}
}

minimal = "{\"providers\": {\"local\": {\"protocol\": \"openai-chat\", \"base_url\": \"http://127.0.0.1:8080/v1\"}}, \"models\": [{\"provider\": \"local\", \"id\": \"qwen\"}], \"works_dir\": \"works\"}"

parsed = |text| Config.parse(JsonValue.decode(text) ?? JsonValue.null)

expect match parsed(minimal) {
	Ok(c) => c.models.map(|m| m.name) == ["qwen"] and c.output_dir == "apo-output" and c.limits == Config.default_limits and c.author == ""
	Err(_) => Bool.False
}

expect parsed(minimal.replace_each("\"works_dir\"", "\"works_dri\"")) == Err("the configuration: unknown key \"works_dri\"; expected one of providers, models, works_dir, output_dir, prompts_dir, limits, author, works")

expect parsed(minimal.replace_each("\"id\": \"qwen\"", "\"id\": \"qwen\", \"temprature\": 0")).is_err()

expect parsed(minimal.replace_each("\"provider\": \"local\"", "\"provider\": \"remote\"")).is_err()

expect parsed(minimal.replace_each("\"works_dir\": \"works\"", "\"works_dir\": \"works\", \"limits\": 3")) == Err("limits must be an object")

expect parsed(minimal.replace_each("\"works_dir\": \"works\"", "\"works_dir\": 3")) == Err("works_dir must be a string")

expect match parsed(minimal.replace_each("\"works_dir\"", "\"author\": {\"name\": \"A\", \"email\": \"a@example.org\"}, \"limits\": {\"max_tokens\": {\"gloss\": 4096}}, \"works\": {\"luke\": {\"label_separator\": \":\"}}, \"works_dir\"")) {
	Ok(c) => c.author == "A <a@example.org>" and c.limits.gloss_tokens == 4096 and c.works == [{ name: "luke", label_separator: ":" }]
	Err(_) => Bool.False
}
