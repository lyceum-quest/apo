# Runs a resolved run: each step over its items, every call through the run store, outputs rebuilt after each step.
# A call whose request is in the store is answered from it; otherwise it goes to the model (paid calls only with
# --paid, and never past the budget), its reply is checked, and an accepted reply is stored before it is used.
import pf.Cmd
import pf.Duration
import pf.Env
import pf.Http
import pf.OsStr
import pf.Path
import pf.Sleep
import pf.Stderr
import http.Request

import apo.Conllu
import apo.Dataset
import apo.JsonValue
import apo.Provider
import apo.Steps

import Io
import Load

Execute :: [].{
	Mode : [Live({ paid : Bool }), Dry]

	StepReport : { kind : Str, items : U64, cached : U64, called : U64, failed : U64, planned : U64, estimate : Dec }

	Report : { label : Str, dir : Str, status : Str, steps : List(StepReport), cost : Dec }

	## The run's directory: its experiment, label, and a hash of everything that determines its output.
	locate! : Load.Run, Str => Try({ id : Str, dir : Str, identity : JsonValue }, [Failed(Str)])
	locate! = |run, version| {
		selected = Dataset.selected(run.dataset, run.passages)
		identity = JsonValue.object([
			("apo", JsonValue.str(version)),
			("model", Provider.identity(run.model, { system: "", user: "", max_tokens: 0 })),
			("steps", JsonValue.list(run.steps.map(|s| JsonValue.object([("kind", JsonValue.str(Steps.name(s.kind))), ("system", JsonValue.str(s.system)), ("max_tokens", JsonValue.u64(s.max_tokens)), ("lang", JsonValue.str(s.lang)), ("punctuation", JsonValue.strs(s.punctuation))])))),
			("dataset", JsonValue.object([
				("name", JsonValue.str(run.dataset.name)),
				("input", JsonValue.str(Io.sha256!(Conllu.serialize(run.sentences))?)),
				("passages", JsonValue.list(selected.map(|p| Steps.unit(p, { prose: "", literal: "" })))),
				("omitted", JsonValue.str(run.dataset.omitted_prefix)),
				("reference", JsonValue.list(run.reference.map(JsonValue.strs))),
			])),
		])
		id = Io.sha256!(JsonValue.canonical(identity))?
		Ok({ id, dir: "${run.runs_dir}/${run.experiment}/${run.label}-${Str.from_utf8(id.to_utf8().take_first(10)) ?? id}", identity })
	}

	run! : Load.Run, Str, Mode => Try(Report, [Failed(Str)])
	run! = |run, version, mode| {
		located = locate!(run, version)?
		dir = located.dir
		selected = Dataset.selected(run.dataset, run.passages)
		needed = Dataset.sentences_needed(run.dataset, run.sentences, selected)
		var $sentences = run.sentences.take_first(needed)
		var $units = []
		var $links = []
		var $spent = spent!(dir)
		var $reports = []
		var $status = "completed"
		started = Io.now!()
		if mode != Dry {
			for (name, text) in run.sources {
				Io.write!("${dir}/config/${name}", text)?
			}
			Io.write!("${dir}/manifest.json", JsonValue.pretty(manifest(run, version, located.id, started, "running", $spent)))?
		}
		ctx = { run, dir, mode, key: Io.key!(run.model) }
		for step in run.steps {
			kind = Steps.name(step.kind)
			var $report = { kind, items: 0, cached: 0, called: 0, failed: 0, planned: 0, estimate: 0 }
			items = match step.kind {
				TranslatePassage => selected.len()
				_ => $sentences.len()
			}
			if step.kind == Align and run.reference.len() < items {
				return Err(Failed("align needs a reference line for each of ${items.to_str()} sentences; the dataset has ${run.reference.len().to_str()}"))
			}
			if mode != Dry and run.model.provider.batch {
				var $calls = []
				var $n = 0
				while $n < items {
					$calls = $calls.append(request(run, step, $sentences, selected, $n))
					$n = $n + 1
				}
				batch!(ctx, kind, $calls)?
			}
			var $i = 0
			while $i < items and $status == "completed" {
				sentence = $sentences.get($i) ?? { line: 0, comments: [], rows: [] }
				label = "${kind} ${($i + 1).to_str()}/${items.to_str()}"
				_ = if mode != Dry Stderr.write!("\r\u(1b)[2K${run.label}: ${label} · $${money($spent)}") else Ok({})
				call = request(run, step, $sentences, selected, $i)
				result = match step.kind {
					TranslateSentence => call!(ctx, $spent, kind, $i, call, |content| Steps.check_translation(Steps.reply_object(content)?)).map_ok(|r| { cost: r.cost, cached: r.cached, apply: TranslatedSentence(r.value) })
					GlossTokens => call!(ctx, $spent, kind, $i, call, |content| Steps.check_glosses(run.dataset, sentence, step.punctuation, Steps.reply_object(content)?)).map_ok(|r| { cost: r.cost, cached: r.cached, apply: Glossed(r.value) })
					TranslatePassage => call!(ctx, $spent, kind, $i, call, |content| Steps.check_translation(Steps.reply_object(content)?)).map_ok(|r| { cost: r.cost, cached: r.cached, apply: TranslatedPassage(r.value) })
					Align => call!(ctx, $spent, kind, $i, call, |content| Steps.check_links(Steps.reply_object(content)?, overt(run.dataset, sentence).len(), (run.reference.get($i) ?? []).len())).map_ok(|r| { cost: r.cost, cached: r.cached, apply: Aligned(r.value) })
				}
				$report = { ..$report, items: $report.items + 1 }
				match result {
					Ok(done) => {
						$spent = $spent + done.cost
						$report = if done.cached { ..$report, cached: $report.cached + 1 } else { ..$report, called: $report.called + 1 }
						match done.apply {
							TranslatedSentence(t) => {
								$sentences = $sentences.set($i, Steps.merge_translation(sentence, $i, step.lang, t)) ?? $sentences
							}
							Glossed(g) => {
								$sentences = $sentences.set($i, Steps.merge_glosses(sentence, g)) ?? $sentences
							}
							TranslatedPassage(t) => {
								$units = $units.append(Steps.unit(selected.get($i) ?? { ref: "", label: "", tokens: [] }, t))
							}
							Aligned(pairs) => {
								$links = $links.append(JsonValue.object([("sentence", JsonValue.u64($i + 1)), ("links", JsonValue.list(pairs.map(|(a, b)| JsonValue.list([JsonValue.u64(a), JsonValue.u64(b)]))))]))
							}
						}
					}
					Err(Planned(estimate)) => {
						$report = { ..$report, planned: $report.planned + 1, estimate: $report.estimate + estimate }
					}
					Err(Stopped({ message, cost })) => {
						$spent = $spent + cost
						$status = "stopped: ${message}"
					}
					Err(Exhausted({ message, cost })) => {
						$spent = $spent + cost
						if run.skip_failures {
							$report = { ..$report, failed: $report.failed + 1 }
							if step.kind == Align {
								$links = $links.append(JsonValue.object([("sentence", JsonValue.u64($i + 1)), ("links", JsonValue.list([])), ("failed", JsonValue.bool(Bool.True))]))
							}
						} else {
							$status = "stopped: ${message}"
						}
					}
					Err(Failed(message)) => return Err(Failed(message))
				}
				$i = $i + 1
			}
			$reports = $reports.append($report)
			if mode != Dry {
				write_outputs!(dir, run.dataset.name, $sentences, selected, $units, $links)?
			}
		}
		if mode != Dry {
			_ = Stderr.write!("\r\u(1b)[2K")
			Io.write!("${dir}/manifest.json", JsonValue.pretty(manifest(run, version, located.id, started, $status, $spent)))?
		}
		Ok({ label: run.label, dir, status: $status, steps: $reports, cost: $spent })
	}

	## The call for item `i` of a step, given the sentences as earlier steps left them.
	request : Load.Run, Load.Step, List(Conllu.Sentence), List(Dataset.Passage), U64 -> Provider.Call
	request = |run, step, sentences, selected, i| {
		sentence = sentences.get(i) ?? { line: 0, comments: [], rows: [] }
		user = match step.kind {
			TranslateSentence => Steps.sentence_input(run.dataset, sentence)
			GlossTokens => Steps.gloss_input(run.dataset, sentence)
			TranslatePassage => Steps.passage_input(run.dataset, sentences, selected.get(i) ?? { ref: "", label: "", tokens: [] })
			Align => Steps.align_input(overt(run.dataset, sentence), run.reference.get(i) ?? [])
		}
		{ system: step.system, user: JsonValue.canonical(user), max_tokens: step.max_tokens }
	}

	## Sends a step's calls that are not in the store as one batch, waits for it to end, and keeps each result in
	## batch/ until `call!` has checked it.
	batch! : Ctx, Str, List(Provider.Call) => Try({}, [Failed(Str)])
	batch! = |ctx, kind, calls| {
		var $pending = []
		for c in calls {
			hash = Io.sha256!(JsonValue.canonical(Provider.identity(ctx.run.model, c)))?
			if !Io.exists!("${ctx.dir}/store/${hash}.json") and !Io.exists!("${ctx.dir}/batch/${hash}.json") and !$pending.any(|(h, _)| h == hash) {
				$pending = $pending.append((hash, c))
			}
		}
		if $pending.is_empty() {
			return Ok({})
		}
		if Provider.paid(ctx.run.model) and ctx.mode == Live({ paid: Bool.False }) {
			return Err(Failed("${ctx.run.model.name} is a paid provider; rerun with --paid"))
		}
		_ = Stderr.line!("${ctx.run.label}: submitting ${$pending.len().to_str()} ${kind} call(s) as a batch")
		submitted = Provider.batch_status(send!(Provider.batch_submit(ctx.run.model, $pending, ctx.key), ctx.run.timeout_seconds).map_err(|e| Failed(e))?).map_err(|e| Failed(e))?
		Io.write!("${ctx.dir}/batch/${submitted.id}.submitted", "")?
		var $status = submitted
		while !$status.ended {
			_ = Sleep.millis!(30000)
			$status = Provider.batch_status(send!(Provider.batch_poll(ctx.run.model, submitted.id, ctx.key), ctx.run.timeout_seconds).map_err(|e| Failed(e))?).map_err(|e| Failed(e))?
		}
		results = send!(Provider.batch_fetch(ctx.run.model, $status.results_url, ctx.key), ctx.run.timeout_seconds).map_err(|e| Failed(e))?
		for (hash, outcome) in Provider.batch_results(results) {
			match outcome {
				Ok(body) => Io.write!("${ctx.dir}/batch/${hash}.json", body)?
				Err(message) => event!(ctx.dir, kind, 0, 1, Bool.False, { input: 0, output: 0, cache_read: 0 }, 0, 0, "error", message)?
			}
		}
		Ok({})
	}

	overt : Dataset.Spec, Conllu.Sentence -> List(Str)
	overt = |spec, s| s.rows.keep_if(|r| !Dataset.is_omitted(spec, r)).map(|r| r.form)

	write_outputs! = |dir, name, sentences, passages, units, links| {
		Io.write!("${dir}/output/${name}.conllu", Conllu.serialize(sentences))?
		Io.write!("${dir}/output/passages.jsonl", Str.join_with(passages.map(|p| "${JsonValue.encode(JsonValue.object([("ref", JsonValue.str(p.ref)), ("label", JsonValue.str(p.label)), ("tokens", JsonValue.strs(p.tokens))]))}\n"), ""))?
		if !units.is_empty() {
			Io.write!("${dir}/output/units.jsonl", Str.join_with(units.map(|u| "${JsonValue.canonical(u)}\n"), ""))?
		}
		if !links.is_empty() {
			Io.write!("${dir}/output/alignments.jsonl", Str.join_with(links.map(|l| "${JsonValue.encode(l)}\n"), ""))?
		}
		Ok({})
	}

	## Money already spent by this run's earlier calls, from its event log.
	spent! : Str => Dec
	spent! = |dir| {
		var $total = 0
		for line in (Io.read!("${dir}/events.jsonl") ?? "").split_on("\n") {
			match JsonValue.decode(line) {
				Ok(event) => {
					$total = $total + ((event.field("cost") ?? JsonValue.Number("0")).as_dec() ?? 0)
				}
				Err(_) => {}
			}
		}
		$total
	}

	manifest = |run, version, id, started, status, spent| JsonValue.object([
		("apo", JsonValue.str(version)),
		("run", JsonValue.str(id)),
		("experiment", JsonValue.str(run.experiment)),
		("label", JsonValue.str(run.label)),
		("model", JsonValue.object([("name", JsonValue.str(run.model.name)), ("provider", JsonValue.str(run.model.provider.name)), ("protocol", JsonValue.str(Provider.protocol_name(run.model.provider.protocol))), ("id", JsonValue.str(run.model.id)), ("options", run.model.options)])),
		("dataset", JsonValue.object([("name", JsonValue.str(run.dataset.name)), ("title", JsonValue.str(run.dataset.title)), ("input", JsonValue.str(run.dataset.input)), ("passages", JsonValue.u64(Dataset.selected(run.dataset, run.passages).len())), ("token_ids", JsonValue.str(if run.dataset.token_ids == Position "position" else "misc-first")), ("first_line", JsonValue.u64(match run.dataset.lines {
			AllLines => 1
			Lines(first, _) => first
		}))])),
		("steps", JsonValue.list(run.steps.map(|s| JsonValue.object([("kind", JsonValue.str(Steps.name(s.kind))), ("prompt", JsonValue.str(s.prompt_file)), ("max_tokens", JsonValue.u64(s.max_tokens))])))),
		("limits", JsonValue.object([("attempts", JsonValue.u64(run.attempts)), ("timeout_seconds", JsonValue.u64(run.timeout_seconds)), ("budget_usd", JsonValue.dec(run.budget))])),
		("started", JsonValue.str(started)),
		("status", JsonValue.str(status)),
		("cost_usd", JsonValue.dec(spent)),
		("replayable", JsonValue.bool(Bool.True)),
	])

	money : Dec -> Str
	money = |n| {
		text = n.to_str()
		match text.split_on(".") {
			[whole, fraction] => "${whole}.${Str.from_utf8(fraction.concat("0000").to_utf8().take_first(4)) ?? "0000"}"
			_ => "${text}.0000"
		}
	}

	Ctx : { run : Load.Run, dir : Str, mode : Mode, key : Str }

	## One call through the store. `check` turns the reply's text into an accepted value or a reason to retry.
	call! : Ctx, Dec, Str, U64, Provider.Call, (Str -> Try(a, Str)) => Try({ value : a, cost : Dec, cached : Bool }, [Failed(Str), Planned(Dec), Stopped({ message : Str, cost : Dec }), Exhausted({ message : Str, cost : Dec })])
	call! = |ctx, spent, kind, index, call, check| {
		identity = Provider.identity(ctx.run.model, call)
		hash = Io.sha256!(JsonValue.canonical(identity))?
		stored = "${ctx.dir}/store/${hash}.json"
		item = index + 1
		if Io.exists!(stored) {
			record = Io.json!(stored)?
			content = ((record.field("reply") ?? JsonValue.null).field("content") ?? JsonValue.null).as_str() ?? ""
			value = check(content).map_err(|m| Failed("${stored} no longer passes the ${kind} checks: ${m}"))?
			if ctx.mode != Dry {
				event!(ctx.dir, kind, item, 0, Bool.True, { input: 0, output: 0, cache_read: 0 }, 0, 0, "accepted", "")?
			}
			return Ok({ value, cost: 0, cached: Bool.True })
		}
		provisional = "${ctx.dir}/batch/${hash}.json"
		if ctx.mode != Dry and Io.exists!(provisional) {
			body = Io.read!(provisional)?
			match Provider.reply(ctx.run.model, body) {
				Ok(reply) => {
					# Batched calls cost half the list price.
					cost = Provider.cost(ctx.run.model, reply) / 2
					tokens = { input: reply.input_tokens, output: reply.output_tokens, cache_read: reply.cache_read_tokens }
					match check(reply.content) {
						Ok(value) => {
							Io.write!(stored, JsonValue.pretty(JsonValue.object([("request", identity), ("reply", JsonValue.object([("content", JsonValue.str(reply.content)), ("input_tokens", JsonValue.u64(reply.input_tokens)), ("output_tokens", JsonValue.u64(reply.output_tokens)), ("cache_read_tokens", JsonValue.u64(reply.cache_read_tokens))])), ("cost_usd", JsonValue.dec(cost)), ("latency_ms", JsonValue.u64(0)), ("attempt", JsonValue.u64(1)), ("batch", JsonValue.bool(Bool.True))])))?
							event!(ctx.dir, kind, item, 1, Bool.False, tokens, cost, 0, "accepted", "batch")?
							_ = Path.delete!(Path.unix(provisional))
							return Ok({ value, cost, cached: Bool.False })
						}
						Err(message) => {
							event!(ctx.dir, kind, item, 1, Bool.False, tokens, cost, 0, "rejected", "batch: ${message}")?
						}
					}
				}
				Err(message) => {
					event!(ctx.dir, kind, item, 1, Bool.False, { input: 0, output: 0, cache_read: 0 }, 0, 0, "error", "batch: ${message}")?
				}
			}
			_ = Path.rename!(Path.unix(provisional), Path.unix("${ctx.dir}/rejected/${hash}-batch.json"))
		}
		if ctx.mode == Dry {
			tokens = (call.system.to_utf8().len() + call.user.to_utf8().len()) // 3
			estimate = (tokens.to_dec() * ctx.run.model.prices.input + call.max_tokens.to_dec() * ctx.run.model.prices.output) / 1000000
			return Err(Planned(estimate))
		}
		if Provider.paid(ctx.run.model) and ctx.mode == Live({ paid: Bool.False }) {
			return Err(Stopped({ message: "${ctx.run.model.name} is a paid provider; rerun with --paid", cost: 0 }))
		}
		if ctx.run.model.provider.key_env != "" and ctx.key == "" {
			return Err(Failed("set ${ctx.run.model.provider.key_env} for provider ${ctx.run.model.provider.name}"))
		}
		var $cost = 0
		var $last = ""
		var $attempt = 1
		while $attempt <= ctx.run.attempts {
			if ctx.run.budget > 0 and spent + $cost >= ctx.run.budget {
				return Err(Stopped({ message: "budget of $${money(ctx.run.budget)} reached", cost: $cost }))
			}
			started = Io.millis!()
			sent = send!(Provider.outbound(ctx.run.model, call, ctx.key), ctx.run.timeout_seconds)
			latency = Io.millis!() - started
			replied = match sent {
				Ok(body) => Provider.reply(ctx.run.model, body)
				Err(m) => Err(m)
			}
			match replied {
				Ok(reply) => {
					cost = Provider.cost(ctx.run.model, reply)
					$cost = $cost + cost
					tokens = { input: reply.input_tokens, output: reply.output_tokens, cache_read: reply.cache_read_tokens }
					match check(reply.content) {
						Ok(value) => {
							record = JsonValue.object([
								("request", identity),
								("reply", JsonValue.object([("content", JsonValue.str(reply.content)), ("input_tokens", JsonValue.u64(reply.input_tokens)), ("output_tokens", JsonValue.u64(reply.output_tokens)), ("cache_read_tokens", JsonValue.u64(reply.cache_read_tokens))])),
								("cost_usd", JsonValue.dec(cost)),
								("latency_ms", JsonValue.u64(latency)),
								("attempt", JsonValue.u64($attempt)),
							])
							Io.write!(stored, JsonValue.pretty(record))?
							event!(ctx.dir, kind, item, $attempt, Bool.False, tokens, cost, latency, "accepted", "")?
							return Ok({ value, cost: $cost, cached: Bool.False })
						}
						Err(message) => {
							Io.write!("${ctx.dir}/rejected/${hash}-${$attempt.to_str()}.json", JsonValue.pretty(JsonValue.object([("request", identity), ("content", JsonValue.str(reply.content)), ("reason", JsonValue.str(message))])))?
							event!(ctx.dir, kind, item, $attempt, Bool.False, tokens, cost, latency, "rejected", message)?
							$last = message
						}
					}
				}
				Err(message) => {
					event!(ctx.dir, kind, item, $attempt, Bool.False, { input: 0, output: 0, cache_read: 0 }, 0, latency, "error", message)?
					$last = message
				}
			}
			$attempt = $attempt + 1
		}
		Err(Exhausted({ message: "${kind} item ${item.to_str()} failed after ${ctx.run.attempts.to_str()} attempt(s): ${$last}", cost: $cost }))
	}

	event! = |dir, kind, item, attempt, cached, tokens, cost, latency, outcome, message|
		Io.append!(
			"${dir}/events.jsonl",
			"${JsonValue.encode(JsonValue.object([
				("at", JsonValue.str(Io.now!())),
				("step", JsonValue.str(kind)),
				("item", JsonValue.u64(item)),
				("attempt", JsonValue.u64(attempt)),
				("cached", JsonValue.bool(cached)),
				("input_tokens", JsonValue.u64(tokens.input)),
				("output_tokens", JsonValue.u64(tokens.output)),
				("cache_read_tokens", JsonValue.u64(tokens.cache_read)),
				("cost", JsonValue.dec(cost)),
				("latency_ms", JsonValue.u64(latency)),
				("outcome", JsonValue.str(outcome)),
				("message", JsonValue.str(message)),
			]))}\n",
		)

	## The response body of a call, or why there is none.
	send! : Provider.Outbound, U64 => Try(Str, Str)
	send! = |outbound, timeout_seconds| match outbound {
		Http(h) => {
			var $request = Request.from_method(if h.method == Get GET else POST).with_uri(h.url).with_body(h.body.to_utf8()).with_timeout(TimeoutMilliseconds(timeout_seconds * 1000))
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
				command = if e.cwd == "" base else base.cwd(Path.unix(e.cwd))
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
