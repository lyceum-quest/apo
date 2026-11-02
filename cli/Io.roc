# Effects shared by the commands: files, hashing, time. Failures carry the path or program they concern.
import pf.Cmd
import pf.Env
import pf.OsStr
import pf.Path
import pf.Utc

import apo.JsonValue

Io :: [].{
	read! : Str => Try(Str, [Failed(Str)])
	read! = |path| Path.read_utf8!(Path.unix(path)).map_err(|_| Failed("cannot read ${path}"))

	write! : Str, Str => Try({}, [Failed(Str)])
	write! = |path, text| {
		mkdir!(dir_of(path))?
		Path.write_utf8!(Path.unix(path), text).map_err(|_| Failed("cannot write ${path}"))
	}

	append! : Str, Str => Try({}, [Failed(Str)])
	append! = |path, text| Path.append_bytes!(Path.unix(path), text.to_utf8()).map_err(|_| Failed("cannot append to ${path}"))

	exists! : Str => Bool
	exists! = |path| Path.exists!(Path.unix(path)) ?? Bool.False

	mkdir! : Str => Try({}, [Failed(Str)])
	mkdir! = |path| if (path == "" or path == ".") Ok({}) else Path.create_all!(Path.unix(path)).map_err(|_| Failed("cannot create ${path}"))

	json! : Str => Try(JsonValue, [Failed(Str)])
	json! = |path| JsonValue.decode(read!(path)?).map_err(|message| Failed("${path}: ${message}"))

	list! : Str => List(Str)
	list! = |dir| (Path.list!(Path.unix(dir)) ?? []).map(|p| Path.display(p))

	## Hex SHA-256 of a text.
	sha256! : Str => Try(Str, [Failed(Str)])
	sha256! = |text| {
		output = Cmd.new("sha256sum").stdin(Bytes(text.to_utf8())).run!().map_err(|_| Failed("cannot run sha256sum"))?
		hex = Str.from_utf8(output.stdout_bytes.take_first(64)) ?? ""
		if (hex.to_utf8().len() == 64) Ok(hex) else Err(Failed("sha256sum gave no digest"))
	}

	now! : () => Str
	now! = || Utc.to_inspect(Utc.now!()).drop_prefix("Utc(").drop_suffix(")")

	millis! : () => U64
	millis! = || Utc.to_millis_since_epoch(Utc.now!()).to_u64_wrap()

	## The folder part of a path, or "." for a bare name.
	dir_of : Str -> Str
	dir_of = |path| match path.split_last("/") {
		Ok({ before, after: _ }) => if (before == "") "/" else before
		Err(_) => "."
	}

	## `relative` resolved against `dir`, unless it is absolute.
	join : Str, Str -> Str
	join = |dir, relative| if (relative.starts_with("/") or dir == ".") relative else "${dir}/${relative}"

	## The file name without folders or extension.
	stem : Str -> Str
	stem = |path| {
		name = match path.split_last("/") {
			Ok({ before: _, after }) => after
			Err(_) => path
		}
		match name.split_last(".") {
			Ok({ before, after: _ }) => before
			Err(_) => name
		}
	}

	## An environment variable's value, or "" when it is unset.
	env! : Str => Str
	env! = |name| Env.var_str!(OsStr.from_str(name)) ?? ""

	## Whether standard input is a terminal (the probe inherits it; a captured child would see a pipe).
	stdin_is_terminal! : () => Bool
	stdin_is_terminal! = || match Cmd.new("test").args(["-t", "0"]).stdin(Inherit).run!() {
		Ok(output) => output.status == Exited(0)
		Err(_) => Bool.False
	}

	os : Str -> OsStr
	os = |s| OsStr.from_str(s)
}
