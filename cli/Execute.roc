# Runs a job: translates and glosses a work's sentences in order, then translates each citation passage its finished
# sentences cover. Every accepted reply is appended to replies.jsonl, keyed by the SHA-256 of its request, before it
# is used; a request found there is answered from it. So a rerun calls the model only for sentences not yet done, and
# the outputs are rebuilt from replies whose requests match the current configuration, never from older ones.
import pf.Cmd
import pf.Duration
import pf.Http
import pf.Stderr
import pf.Path
import http.Request

import apo.Conllu
import apo.Dataset
import apo.JsonValue
import apo.Provider
import apo.Steps

import Io
import Load

Execute :: [].{
	Report : { dir : Str, generated : U64, sentences : U64, total : U64, passages : U64, total_passages : U64 }

	Ctx : { job : Load.Job, dir : Str, cache : Dict(Str, Str), key : Str }

	## Translates and glosses up to `count` sentences not yet done, and every passage they complete.
	run! : Load.Job, U64, Bool, Str => Try(Report, [Failed(Str)])
	run! = |job, count, fresh, version| {
		dir = job.dir
		fingerprint = Io.sha256!(
			JsonValue.canonical(
				JsonValue.object([
					("model", Provider.identity(job.model, { system: "", user: "", max_tokens: 0 })),
					("steps", JsonValue.list([job.translate, job.gloss, job.passage].map(|s| JsonValue.object([("kind", JsonValue.str(Steps.name(s.kind))), ("system", JsonValue.str(s.system)), ("max_tokens", JsonValue.u64(s.max_tokens))])))),
				]),
			),
		)?
		if !fresh {
			unchanged!(dir, fingerprint)?
		}
		ctx = { job, dir, cache: cache!(dir)?, key: Io.key!(job.model) }
		if job.model.provider.key_env != "" and ctx.key == "" {
			return Err(Failed("set ${job.model.provider.key_env} for provider ${job.model.provider.name}"))
		}
		spec = job.work.spec
		sentences = job.work.sentences
		header = { name: job.work.name, model: job.model.id, fingerprint, version, author: job.author }
		var $done = []
		var $generated = 0
		var $more = Bool.True
		while $more and $done.len() < sentences.len() {
			i = $done.len()
			item = "sentence ${(i + 1).to_str()}"
			sentence = sentences.get(i) ?? { line: 0, comments: [], rows: [] }
			translate_call = { system: job.translate.system, user: JsonValue.canonical(Steps.sentence_input(spec, sentence)), max_tokens: job.translate.max_tokens }
			translate_hash = hash!(job.model, translate_call)?
			if !ctx.cache.contains(translate_hash) and $generated >= count {
				$more = Bool.False
			} else {
				translation = answer!(ctx, TranslateSentence, item, translate_hash, translate_call, |content| Steps.check_translation(Steps.reply_object(content)?))?
				translated = Steps.merge_translation(sentence, i, "en", translation.value)
				gloss_call = { system: job.gloss.system, user: JsonValue.canonical(Steps.gloss_input(spec, translated)), max_tokens: job.gloss.max_tokens }
				gloss_hash = hash!(job.model, gloss_call)?
				if !ctx.cache.contains(gloss_hash) and !translation.called and $generated >= count {
					$more = Bool.False
				} else {
					glosses = answer!(ctx, GlossTokens, item, gloss_hash, gloss_call, |content| Steps.check_glosses(spec, translated, ["u", "PUNCT"], Steps.reply_object(content)?))?
					$done = $done.append(Steps.merge_glosses(translated, glosses.value))
					if translation.called or glosses.called {
						$generated = $generated + 1
						write!(dir, header, $done, [], Bool.False)?
						_ = Stderr.line!("${job.work.name}/${job.model.name}: ${item} of ${sentences.len().to_str()} done (${$generated.to_str()} new)")
					}
				}
			}
		}
		# A passage is translated once every sentence holding its tokens is done.
		var $finished = Dict.empty()
		var $index = 0
		for s in $done {
			for t in Dataset.tokens(spec, $index, s) {
				$finished = $finished.insert(t, {})
			}
			$index = $index + 1
		}
		var $units = []
		for passage in job.work.passages {
			if passage.tokens.all(|t| $finished.contains(t)) {
				call = { system: job.passage.system, user: JsonValue.canonical(Steps.passage_input(spec, $done, passage)), max_tokens: job.passage.max_tokens }
				translation = answer!(ctx, TranslatePassage, "passage ${passage.label}", hash!(job.model, call)?, call, |content| Steps.check_translation(Steps.reply_object(content)?))?
				$units = $units.append(Steps.unit(passage, translation.value))
			}
		}
		write!(dir, header, $done, $units, job.work.has_refs)?
		Ok({ dir, generated: $generated, sentences: $done.len(), total: sentences.len(), passages: $units.len(), total_passages: job.work.passages.len() })
	}

	## Stops a run that would mix outputs: the folder's output was made with another model, prompt, context, or limit.
	unchanged! : Str, Str => Try({}, [Failed(Str)])
	unchanged! = |dir, fingerprint| {
		path = "${dir}/output.conllu"
		if !Io.exists!(path) {
			return Ok({})
		}
		first = match Conllu.parse(Io.read!(path)?) {
			Ok([s, ..]) => s
			_ => return Ok({})
		}
		if Conllu.comment(first, "config_sha256") == Ok(fingerprint) {
			Ok({})
		} else {
			model = Conllu.comment(first, "model") ?? "an unknown model"
			Err(Failed("${path} was made by ${model} with a different model, prompt, context or limit. Write to another output_dir, or pass --fresh to start this work over."))
		}
	}

	## Accepted replies by request hash.
	cache! : Str => Try(Dict(Str, Str), [Failed(Str)])
	cache! = |dir| {
		var $out = Dict.empty()
		for line in (Io.read!("${dir}/replies.jsonl") ?? "").split_on("\n") {
			if line.trim() != "" {
				record = JsonValue.decode(line).map_err(|m| Failed("${dir}/replies.jsonl: ${m}"))?
				text = |key| (record.field(key) ?? JsonValue.null).as_str() ?? ""
				$out = $out.insert(text("request_sha256"), text("content"))
			}
		}
		Ok($out)
	}

	hash! : Provider.Model, Provider.Call => Try(Str, [Failed(Str)])
	hash! = |model, call| Io.sha256!(JsonValue.canonical(Provider.identity(model, call)))

	## The accepted value of a call: from the cache, or from the model, retried until a reply passes `check`.
	answer! : Ctx, Steps.Kind, Str, Str, Provider.Call, (Str -> Try(a, Str)) => Try({ value : a, called : Bool }, [Failed(Str)])
	answer! = |ctx, kind, item, hash, call, check| {
		step = Steps.name(kind)
		match ctx.cache.get(hash) {
			Ok(content) => {
				value = check(content).map_err(|m| Failed("${ctx.dir}/replies.jsonl: the stored ${step} reply for ${item} no longer passes its checks: ${m}"))?
				return Ok({ value, called: Bool.False })
			}
			Err(_) => {}
		}
		var $last = ""
		var $attempt = 1
		while $attempt <= ctx.job.attempts {
			replied = match send!(Provider.outbound(ctx.job.model, call, ctx.key), ctx.job.timeout_seconds) {
				Ok(body) => Provider.reply(ctx.job.model, body)
				Err(m) => Err(m)
			}
			match replied {
				Ok(reply) => match check(reply.content) {
					Ok(value) => {
						record = JsonValue.object([
							("step", JsonValue.str(step)),
							("item", JsonValue.str(item)),
							("request_sha256", JsonValue.str(hash)),
							("content", JsonValue.str(reply.content)),
							("input_tokens", JsonValue.u64(reply.input_tokens)),
							("output_tokens", JsonValue.u64(reply.output_tokens)),
						])
						Io.mkdir!(ctx.dir)?
						Io.append!("${ctx.dir}/replies.jsonl", "${JsonValue.encode(record)}\n")?
						return Ok({ value, called: Bool.True })
					}
					Err(message) => {
						$last = "${message}; the reply began: ${Str.from_utf8(reply.content.to_utf8().take_first(300)) ?? ""}"
					}
				}
				Err(message) => {
					$last = message
				}
			}
			$attempt = $attempt + 1
		}
		Err(Failed("${step} for ${item} failed after ${ctx.job.attempts.to_str()} attempt(s): ${$last}"))
	}

	## Writes output.conllu (the done sentences, the first carrying the header) and, for a work with citations,
	## units.jsonl.
	write! = |dir, header, sentences, units, with_units| {
		var $out = []
		for s in sentences {
			n = $out.len() + 1
			sent_id = if (Conllu.comment(s, "sent_id").is_ok()) [] else ["# sent_id = ${header.name}-${n.to_str()}"]
			text = if (Conllu.comment(s, "text").is_ok()) [] else ["# text = ${Conllu.text(s)}"]
			own = sent_id.concat(text)
			first = if (n == 1) ["# newdoc id = ${header.name}", "# generator = apo ${header.version}", "# model = ${header.model}", "# config_sha256 = ${header.fingerprint}"].concat(if (header.author == "") [] else ["# generated_by = ${header.author}"]) else []
			$out = $out.append({ ..s, comments: first.concat(own).concat(s.comments) })
		}
		Io.write!("${dir}/output.conllu", Conllu.serialize($out))?
		if with_units {
			Io.write!("${dir}/units.jsonl", Str.join_with(units.map(|u| "${JsonValue.canonical(u)}\n"), ""))?
		}
		Ok({})
	}

	## The response body of a call, or why there is none.
	send! : Provider.Outbound, U64 => Try(Str, Str)
	send! = |outbound, timeout_seconds| match outbound {
		Http(h) => {
			var $request = Request.from_method(POST).with_uri(h.url).with_body(h.body.to_utf8()).with_timeout(TimeoutMilliseconds(timeout_seconds * 1000))
			for (name, value) in h.headers {
				$request = $request.add_header(name, value)
			}
			match Http.send!($request, {}) {
				Ok(response) => {
					body = Str.from_utf8(response.body()) ?? ""
					if response.status() >= 200 and response.status() < 300 {
						Ok(body)
					} else {
						Err("HTTP ${response.status().to_str()}: ${Str.from_utf8(body.to_utf8().take_first(500)) ?? ""}")
					}
				}
				Err(e) => Err("HTTP request failed: ${Str.inspect(e)}")
			}
		}
		Exec(e) => match e.argv {
			[program, .. as args] => {
				base = Cmd.new(Io.os(program)).args(args.map(Io.os)).envs(e.env.map(|(k, v)| (Io.os(k), Io.os(v)))).stdin(Bytes(e.stdin.to_utf8())).timeout(Duration.seconds(timeout_seconds))
				command = if (e.cwd == "") base else base.cwd(Path.unix(e.cwd))
				match command.run!() {
					Ok(output) => match output.status {
						Exited(0) => Ok(Str.from_utf8(output.stdout_bytes) ?? "")
						status => Err("${program} ended with ${Str.inspect(status)}: ${Str.from_utf8(output.stderr_bytes.take_first(500)) ?? ""}")
					}
					Err(err) => Err("${program} could not run: ${Str.inspect(err)}")
				}
			}
			[] => Err("empty command")
		}
	}
}
