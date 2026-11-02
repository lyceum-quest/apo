import JsonValue

## Providers and models. A protocol is code (how to send a call and read the reply); an endpoint is configuration.
##   openai-chat: POST <base_url>/chat/completions. OpenRouter, PPQ, vLLM, llama.cpp, Ollama and others.
##   claude-cli:  `claude -p` on the local Claude Code login.
##   command:     any program: the call as JSON on stdin, `{ "content", "input_tokens", "output_tokens" }` on stdout
##                (only `content` is required).
## API keys are read from the environment variable a provider names, and never stored.
Provider :: [].{
	Protocol : [OpenAiChat, ClaudeCli, Command(List(Str))]

	Settings : { name : Str, protocol : Protocol, base_url : Str, key_env : Str, headers : List((Str, Str)) }

	Model : { name : Str, provider : Settings, id : Str, options : JsonValue }

	Call : { system : Str, user : Str, max_tokens : U64 }

	Outbound : [
		Http({ url : Str, headers : List((Str, Str)), body : Str }),
		Exec({ argv : List(Str), env : List((Str, Str)), cwd : Str, stdin : Str }),
	]

	Reply : { content : Str, input_tokens : U64, output_tokens : U64 }

	protocol_name : Protocol -> Str
	protocol_name = |p| match p {
		OpenAiChat => "openai-chat"
		ClaudeCli => "claude-cli"
		Command(_) => "command"
	}

	## A provider from its config entry: `{ "protocol", "base_url", "key_env", "headers", "command" }`.
	settings : Str, JsonValue -> Try(Settings, Str)
	settings = |name, p| {
		text = |key| (p.field(key) ?? JsonValue.str("")).as_str() ?? ""
		protocol = match text("protocol") {
			"openai-chat" => OpenAiChat
			"claude-cli" => ClaudeCli
			"command" => {
				argv = (p.field("command") ?? JsonValue.list([])).items().map(|a| a.as_str() ?? "")
				if argv.is_empty() or argv.contains("") {
					return Err("provider ${name}: command needs a non-empty list of strings")
				}
				Command(argv)
			}
			other => return Err("provider ${name}: unknown protocol \"${other}\"; expected openai-chat, claude-cli or command")
		}
		if protocol == OpenAiChat and text("base_url") == "" {
			return Err("provider ${name}: openai-chat needs base_url")
		}
		headers = (p.field("headers") ?? JsonValue.object([])).fields().map(|(k, v)| (k, v.as_str() ?? ""))
		Ok({ name, protocol, base_url: text("base_url").drop_suffix("/"), key_env: text("key_env"), headers })
	}

	## What determines a reply: hashed for the reply cache. The key and the endpoint's credentials are not part of it.
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
			auth = if (key == "") [] else [("Authorization", "Bearer ${key}")]
			Http({ url: "${m.provider.base_url}/chat/completions", headers: auth.concat(m.provider.headers).append(("Content-Type", "application/json")), body: JsonValue.encode(body) })
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

	## The reply's text and token counts.
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
				Ok({ content, input_tokens: count(usage, "prompt_tokens"), output_tokens: count(usage, "completion_tokens") })
			}
			ClaudeCli => {
				if (json.field("is_error") ?? JsonValue.bool(Bool.False)).as_bool() == Ok(Bool.True) {
					return Err("claude reported an error: ${(json.field("result") ?? JsonValue.null).as_str() ?? ""}")
				}
				usage = json.field("usage") ?? JsonValue.object([])
				Ok({ content: (json.field("result") ?? JsonValue.null).as_str() ?? "", input_tokens: count(usage, "input_tokens") + count(usage, "cache_creation_input_tokens") + count(usage, "cache_read_input_tokens"), output_tokens: count(usage, "output_tokens") })
			}
			Command(_) => Ok({
				content: (json.field("content") ?? return Err("the command's reply has no content")).as_str() ?? "",
				input_tokens: count(json, "input_tokens"),
				output_tokens: count(json, "output_tokens"),
			})
		}
	}
}

local = { name: "local", provider: { name: "local", protocol: OpenAiChat, base_url: "http://127.0.0.1:8080/v1", key_env: "", headers: [] }, id: "qwen", options: JsonValue.object([("temperature", JsonValue.Number("0"))]) }

expect match Provider.outbound(local, { system: "S", user: "U", max_tokens: 10 }, "") {
	Http(h) => h.url == "http://127.0.0.1:8080/v1/chat/completions" and h.body == "{\"model\":\"qwen\",\"max_tokens\":10,\"messages\":[{\"role\":\"system\",\"content\":\"S\"},{\"role\":\"user\",\"content\":\"U\"}],\"temperature\":0}" and h.headers == [("Content-Type", "application/json")]
	Exec(_) => Bool.False
}

expect match Provider.reply(local, "{\"choices\":[{\"message\":{\"content\":\"{}\"}}],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3}}") {
	Ok(r) => r.content == "{}" and r.input_tokens == 7 and r.output_tokens == 3
	Err(_) => Bool.False
}

expect Provider.settings("x", JsonValue.decode("{\"protocol\": \"command\", \"command\": [\"echo\"]}") ?? JsonValue.null).map_ok(|p| p.protocol) == Ok(Command(["echo"]))

expect Provider.settings("x", JsonValue.decode("{\"protocol\": \"openai-chat\"}") ?? JsonValue.null).is_err()

# The cache key must not change: replies stored by earlier versions stay valid.
expect JsonValue.canonical(Provider.identity(local, { system: "S", user: "U", max_tokens: 1 })) == "{\"base_url\":\"http://127.0.0.1:8080/v1\",\"max_tokens\":1,\"model\":\"qwen\",\"options\":{\"temperature\":0},\"protocol\":\"openai-chat\",\"system\":\"S\",\"user\":\"U\"}"
