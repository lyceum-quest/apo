import JsonValue

## Providers and models. A protocol is code (how to send a call and read the reply); an endpoint is configuration.
##   openai-chat:        POST <base_url>/chat/completions. OpenRouter, PPQ, vLLM, llama.cpp, Ollama and others.
##   anthropic-messages: POST <base_url>/v1/messages, with the system prompt cached between calls.
##   claude-cli:         `claude -p` on the local Claude Code login.
##   command:            any program: the call as JSON on stdin, `{ "content", "input_tokens", "output_tokens",
##                       "cost" }` on stdout (only `content` is required).
## API keys are read from the environment variable a provider names, and never stored.
Provider :: [].{
	Protocol : [OpenAiChat, AnthropicMessages, ClaudeCli, Command(List(Str))]

	Settings : { name : Str, protocol : Protocol, base_url : Str, key_env : Str, headers : List((Str, Str)) }

	Prices : { input : Dec, output : Dec, cache_read : Dec }

	Model : { name : Str, provider : Settings, id : Str, options : JsonValue, prices : Prices }

	Call : { system : Str, user : Str, max_tokens : U64 }

	Outbound : [
		Http({ url : Str, headers : List((Str, Str)), body : Str }),
		Exec({ argv : List(Str), env : List((Str, Str)), cwd : Str, stdin : Str }),
	]

	Reply : { content : Str, input_tokens : U64, output_tokens : U64, cache_read_tokens : U64, reported_cost : [Reported(Dec), Unknown] }

	protocol_name : Protocol -> Str
	protocol_name = |p| match p {
		OpenAiChat => "openai-chat"
		AnthropicMessages => "anthropic-messages"
		ClaudeCli => "claude-cli"
		Command(_) => "command"
	}

	## The providers in providers.json: `{ "providers": { "<name>": { "protocol", "base_url", "key_env", "headers",
	## "command" } } }`.
	settings : JsonValue -> Try(List(Settings), Str)
	settings = |json| {
		var $out = []
		for (name, p) in (json.field("providers") ?? return Err("providers.json needs a providers object")).fields() {
			text = |key| (p.field(key) ?? JsonValue.str("")).as_str() ?? ""
			protocol = match text("protocol") {
				"openai-chat" => OpenAiChat
				"anthropic-messages" => AnthropicMessages
				"claude-cli" => ClaudeCli
				"command" => {
					argv = (p.field("command") ?? JsonValue.list([])).items().map(|a| a.as_str() ?? "")
					if argv.is_empty() or argv.contains("") {
						return Err("provider ${name}: command needs a non-empty list of strings")
					}
					Command(argv)
				}
				other => return Err("provider ${name}: unknown protocol ${other}")
			}
			base = match (protocol, text("base_url")) {
				(AnthropicMessages, "") => "https://api.anthropic.com"
				(OpenAiChat, "") => return Err("provider ${name}: openai-chat needs base_url")
				(_, url) => url
			}
			headers = (p.field("headers") ?? JsonValue.object([])).fields().map(|(k, v)| (k, v.as_str() ?? ""))
			$out = $out.append({ name, protocol, base_url: base.drop_suffix("/"), key_env: text("key_env"), headers })
		}
		Ok($out)
	}

	## A model from an experiment's `models` entry: `{ "name", "provider", "id", "options", "prices": { "input",
	## "output", "cache_read" } }` with prices in US dollars per million tokens.
	model : JsonValue, List(Settings) -> Try(Model, Str)
	model = |json, providers| {
		text = |key| (json.field(key) ?? JsonValue.str("")).as_str() ?? ""
		provider_name = text("provider")
		provider = match providers.keep_if(|p| p.name == provider_name) {
			[p, ..] => p
			[] => return Err("model ${text("name")}: no provider named ${provider_name}")
		}
		prices = json.field("prices") ?? JsonValue.object([])
		price = |key| (prices.field(key) ?? JsonValue.Number("0")).as_dec() ?? 0
		if text("name") == "" or text("id") == "" {
			return Err("every model needs a name and an id")
		}
		Ok({ name: text("name"), provider, id: text("id"), options: json.field("options") ?? JsonValue.object([]), prices: { input: price("input"), output: price("output"), cache_read: price("cache_read") } })
	}

	## Whether a call costs money: it reaches a provider through an API key.
	paid : Model -> Bool
	paid = |m| m.provider.key_env != ""

	## What determines a reply: hashed for the run store. The key and the endpoint's credentials are not part of it.
	identity : Model, Call -> JsonValue
	identity = |m, c| JsonValue.object([
		("protocol", JsonValue.str(protocol_name(m.provider.protocol))),
		("base_url", JsonValue.str(m.provider.base_url)),
		("model", JsonValue.str(m.id)),
		("options", m.options),
		("system", JsonValue.str(c.system)),
		("user", JsonValue.str(c.user)),
		("max_tokens", JsonValue.u64(c.max_tokens)),
	])

	## The call to make. `key` is the API key's value, or "" when the provider needs none.
	outbound : Model, Call, Str -> Outbound
	outbound = |m, c, key| match m.provider.protocol {
		OpenAiChat => {
			body = JsonValue.merge(
				JsonValue.object([
					("model", JsonValue.str(m.id)),
					("max_tokens", JsonValue.u64(c.max_tokens)),
					("messages", JsonValue.list([message("system", c.system), message("user", c.user)])),
				]),
				m.options,
			)
			auth = if key == "" [] else [("Authorization", "Bearer ${key}")]
			Http({ url: "${m.provider.base_url}/chat/completions", headers: auth.concat(m.provider.headers).append(("Content-Type", "application/json")), body: JsonValue.encode(body) })
		}
		AnthropicMessages => {
			system = JsonValue.list([JsonValue.object([("type", JsonValue.str("text")), ("text", JsonValue.str(c.system)), ("cache_control", JsonValue.object([("type", JsonValue.str("ephemeral"))]))])])
			body = JsonValue.merge(
				JsonValue.object([
					("model", JsonValue.str(m.id)),
					("max_tokens", JsonValue.u64(c.max_tokens)),
					("system", system),
					("messages", JsonValue.list([message("user", c.user)])),
				]),
				m.options,
			)
			Http({ url: "${m.provider.base_url}/v1/messages", headers: [("x-api-key", key), ("anthropic-version", "2023-06-01")].concat(m.provider.headers).append(("Content-Type", "application/json")), body: JsonValue.encode(body) })
		}
		ClaudeCli => Exec({
			argv: ["claude", "-p", "--model", m.id, "--system-prompt", c.system, "--output-format", "json", "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence", "--setting-sources", "", c.user],
			env: [("MAX_THINKING_TOKENS", "0")],
			cwd: "/tmp",
			stdin: "",
		})
		Command(argv) => Exec({ argv, env: [], cwd: "", stdin: JsonValue.encode(JsonValue.object([("model", JsonValue.str(m.id)), ("options", m.options), ("system", JsonValue.str(c.system)), ("user", JsonValue.str(c.user)), ("max_tokens", JsonValue.u64(c.max_tokens))])) })
	}

	message : Str, Str -> JsonValue
	message = |role, content| JsonValue.object([("role", JsonValue.str(role)), ("content", JsonValue.str(content))])

	## The reply's text, token counts, and cost when the provider reports one.
	reply : Model, Str -> Try(Reply, Str)
	reply = |m, body| {
		json = JsonValue.decode(body.trim()).map_err(|e| "the provider's reply is not JSON: ${e}")?
		count = |v, key| (v.field(key) ?? JsonValue.Number("0")).as_u64() ?? 0
		match m.provider.protocol {
			OpenAiChat => {
				if json.field("error").is_ok() {
					return Err("the provider returned an error: ${JsonValue.encode(json.field("error") ?? JsonValue.null)}")
				}
				content = match (json.field("choices") ?? JsonValue.null).items() {
					[choice, ..] => ((choice.field("message") ?? JsonValue.null).field("content") ?? JsonValue.null).as_str() ?? ""
					[] => return Err("the reply has no choices")
				}
				usage = json.field("usage") ?? JsonValue.object([])
				cached = (usage.field("prompt_tokens_details") ?? JsonValue.object([])).field("cached_tokens") ?? JsonValue.Number("0")
				Ok({ content, input_tokens: count(usage, "prompt_tokens"), output_tokens: count(usage, "completion_tokens"), cache_read_tokens: cached.as_u64() ?? 0, reported_cost: reported(usage.field("cost")) })
			}
			AnthropicMessages => {
				if json.field("error").is_ok() {
					return Err("the provider returned an error: ${JsonValue.encode(json.field("error") ?? JsonValue.null)}")
				}
				texts = (json.field("content") ?? JsonValue.null).items().keep_if(|b| (b.field("type") ?? JsonValue.null).as_str() == Ok("text"))
				content = Str.join_with(texts.map(|b| (b.field("text") ?? JsonValue.null).as_str() ?? ""), "")
				usage = json.field("usage") ?? JsonValue.object([])
				Ok({ content, input_tokens: count(usage, "input_tokens") + count(usage, "cache_creation_input_tokens"), output_tokens: count(usage, "output_tokens"), cache_read_tokens: count(usage, "cache_read_input_tokens"), reported_cost: Unknown })
			}
			ClaudeCli => {
				if (json.field("is_error") ?? JsonValue.bool(Bool.False)).as_bool() == Ok(Bool.True) {
					return Err("claude reported an error: ${(json.field("result") ?? JsonValue.null).as_str() ?? ""}")
				}
				usage = json.field("usage") ?? JsonValue.object([])
				Ok({
					content: (json.field("result") ?? JsonValue.null).as_str() ?? "",
					input_tokens: count(usage, "input_tokens") + count(usage, "cache_creation_input_tokens"),
					output_tokens: count(usage, "output_tokens"),
					cache_read_tokens: count(usage, "cache_read_input_tokens"),
					reported_cost: reported(json.field("total_cost_usd")),
				})
			}
			Command(_) => Ok({
				content: (json.field("content") ?? return Err("the command's reply has no content")).as_str() ?? "",
				input_tokens: count(json, "input_tokens"),
				output_tokens: count(json, "output_tokens"),
				cache_read_tokens: count(json, "cache_read_tokens"),
				reported_cost: reported(json.field("cost")),
			})
		}
	}

	## Long decimals (JavaScript prints 0.0008872000000000001) are cut to Dec's 18 places.
	reported : Try(JsonValue, _) -> [Reported(Dec), Unknown]
	reported = |field| match field {
		Ok(JsonValue.Number(text)) => {
			short = match text.split_on(".") {
				[whole, fraction] => "${whole}.${Str.from_utf8(fraction.to_utf8().take_first(18)) ?? "0"}"
				_ => text
			}
			match Dec.from_str(short) {
				Ok(n) => Reported(n)
				Err(_) => Unknown
			}
		}
		_ => Unknown
	}

	## The provider's reported cost, else the model's prices applied to the token counts.
	cost : Model, Reply -> Dec
	cost = |m, r| match r.reported_cost {
		Reported(n) => n
		Unknown => {
			fresh = r.input_tokens.to_dec() * m.prices.input
			cached = r.cache_read_tokens.to_dec() * m.prices.cache_read
			out = r.output_tokens.to_dec() * m.prices.output
			(fresh + cached + out) / 1000000
		}
	}
}

local = { name: "local", provider: { name: "local", protocol: OpenAiChat, base_url: "http://127.0.0.1:8080/v1", key_env: "", headers: [] }, id: "qwen", options: JsonValue.object([("temperature", JsonValue.Number("0"))]), prices: { input: 0, output: 0, cache_read: 0 } }

expect match Provider.outbound(local, { system: "S", user: "U", max_tokens: 10 }, "") {
	Http(h) => h.url == "http://127.0.0.1:8080/v1/chat/completions" and h.body == "{\"model\":\"qwen\",\"max_tokens\":10,\"messages\":[{\"role\":\"system\",\"content\":\"S\"},{\"role\":\"user\",\"content\":\"U\"}],\"temperature\":0}" and h.headers == [("Content-Type", "application/json")]
	Exec(_) => Bool.False
}

expect match Provider.reply(local, "{\"choices\":[{\"message\":{\"content\":\"{}\"}}],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3,\"cost\":0.0008872000000000001}}") {
	Ok(r) => r.content == "{}" and r.input_tokens == 7 and r.reported_cost == Reported(0.000887200000000000)
	Err(_) => Bool.False
}

expect {
	anthropic = { ..local, provider: { ..local.provider, protocol: AnthropicMessages, base_url: "https://api.anthropic.com" }, prices: { input: 3, output: 15, cache_read: 0.3 } }
	match Provider.reply(anthropic, "{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"usage\":{\"input_tokens\":1000000,\"output_tokens\":0,\"cache_read_input_tokens\":1000000}}") {
		Ok(r) => r.content == "hi" and Provider.cost(anthropic, r) == 3.3
		Err(_) => Bool.False
	}
}

expect Provider.settings(JsonValue.decode("{\"providers\": {\"x\": {\"protocol\": \"command\", \"command\": [\"echo\"]}}}") ?? JsonValue.null).map_ok(|ps| ps.map(|p| p.protocol)) == Ok([Command(["echo"])])
