import JsonValue

## The providers `apo init` and `apo login` offer (`providers.json`): local servers and Claude Code first, then hosted
## APIs, the long tail from models.dev (MIT). A config names its provider in full, so this list is only a convenience.
Catalog :: [].{
	Entry : { id : Str, name : Str, protocol : Str, base_url : Str, key_env : Str, max_tokens_key : Str, local : Bool }

	parse : Str -> Try(List(Entry), Str)
	parse = |text| {
		json = JsonValue.decode(text)?
		Ok(
			json.items().map(
				|e| {
					field = |key| (e.field(key) ?? JsonValue.str("")).as_str() ?? ""
					protocol = if (field("protocol") == "") "openai-chat" else field("protocol")
					local = (e.field("local") ?? JsonValue.bool(Bool.False)).as_bool() ?? Bool.False
					{ id: field("id"), name: field("name"), protocol, base_url: field("base_url"), key_env: field("env"), max_tokens_key: field("max_tokens_key"), local }
				},
			),
		)
	}

	## Whether the entry can take a stored key: every hosted API, and a server at a URL the user gives.
	takes_key : Entry -> Bool
	takes_key = |e| e.protocol != "claude-cli" and (!e.local or e.id == "server")

	## A provider's entry in `config.json`.
	config : Entry, Str, Str -> JsonValue
	config = |e, base_url, key_env| {
		optional = [("base_url", base_url), ("key_env", key_env), ("max_tokens_key", e.max_tokens_key)].keep_if(|(_, v)| v != "")
		JsonValue.object([("protocol", JsonValue.str(e.protocol))].concat(optional.map(|(k, v)| (k, JsonValue.str(v)))))
	}
}

expect Catalog.parse("[{\"id\": \"a\", \"name\": \"A\", \"base_url\": \"http://x/v1\", \"env\": \"A_KEY\"}]") == Ok([{ id: "a", name: "A", protocol: "openai-chat", base_url: "http://x/v1", key_env: "A_KEY", max_tokens_key: "", local: Bool.False }])
