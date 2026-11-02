# Stored API keys: $XDG_DATA_HOME/apo/auth.json, else ~/.local/share/apo/auth.json, readable only by its owner and
# kept apart from config.json so a configuration can be shared. `{ "<provider>": { "type": "api_key", "key": "…" } }`.
import pf.Cmd

import apo.JsonValue
import apo.Provider

import Io

Auth :: [].{
	path! : () => Str
	path! = || {
		given = Io.env!("XDG_DATA_HOME")
		if (given != "") "${given}/apo/auth.json" else "${Io.env!("HOME")}/.local/share/apo/auth.json"
	}

	read! : () => Try(List((Str, JsonValue)), [Failed(Str)])
	read! = || {
		file = path!()
		if (Io.exists!(file)) Ok(Io.json!(file)?.fields()) else Ok([])
	}

	stored! : Str => Try(Str, [Failed(Str)])
	stored! = |provider| {
		for (name, entry) in read!()? {
			if name == provider {
				return Ok((entry.field("key") ?? JsonValue.str("")).as_str() ?? "")
			}
		}
		Ok("")
	}

	## A provider's key: the stored one, else the environment variable it names, else "". The first matters when
	## both exist, as in pi.
	key! : Provider.Settings => Try(Str, [Failed(Str)])
	key! = |provider| {
		saved = stored!(provider.name)?
		if (saved != "" or provider.key_env == "") Ok(saved) else Ok(Io.env!(provider.key_env))
	}

	store! : Str, Str => Try({}, [Failed(Str)])
	store! = |provider, key| {
		entry = JsonValue.object([("type", JsonValue.str("api_key")), ("key", JsonValue.str(key))])
		write!(read!()?.keep_if(|(name, _)| name != provider).append((provider, entry)))
	}

	## Whether a stored key was removed.
	remove! : Str => Try(Bool, [Failed(Str)])
	remove! = |provider| {
		entries = read!()?
		kept = entries.keep_if(|(name, _)| name != provider)
		if kept.len() == entries.len() {
			return Ok(Bool.False)
		}
		write!(kept)?
		Ok(Bool.True)
	}

	## The file is restricted before a key is written to it: basic-cli cannot create a file with a mode (see
	## IMPROVEMENT-004 in roc-issues), so `chmod` runs on an empty one first.
	write! : List((Str, JsonValue)) => Try({}, [Failed(Str)])
	write! = |entries| {
		file = path!()
		Io.mkdir!(Io.dir_of(file))?
		if !Io.exists!(file) {
			Io.write!(file, "")?
		}
		output = Cmd.new("chmod").args([Io.os("600"), Io.os(file)]).run!().map_err(|_| Failed("cannot run chmod"))?
		if output.status != Exited(0) {
			return Err(Failed("cannot restrict ${file}"))
		}
		Io.write!(file, "${JsonValue.pretty(JsonValue.object(entries))}\n")
	}
}
