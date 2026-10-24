# apo design

apo (ἀπό, "from") derives annotated text from source corpora with language models, and measures how good the result
is. A researcher describes models, prompts, and steps in configuration files; apo runs them over CoNLL-U input,
checks every reply, writes standard CoNLL-U output, and scores and compares runs against external gold data.
It is built for Ancient Greek first and for comparing models, open-weight ones especially, but nothing in it names a
model, a provider, or a corpus.

## Scope

- **In scope:** running configured steps over CoNLL-U; validating CoNLL-U; storing every request and reply so runs
  can be replayed, re-scored, and audited; evaluating runs against gold data; comparing runs with each other.
- **Out of scope:** being a data archive (outputs go to a consumer such as Archeion); a review user interface (apo
  exports and imports review sheets); training or fine-tuning models; owning any gold data.

## Principles

- **The tool owns structure; the model owns meaning.** Token IDs, sentence identity, row order, and serialization
  are never model output. A model returns a small patch (glosses keyed by the IDs it was given, two translation
  strings), apo checks it, and apo writes the file. Earlier experiments in Archeion showed models dropping and
  renumbering rows whenever they were allowed to own the format.
- **Everything is configuration except the steps.** Models, providers, prompts, datasets, and experiments are data.
  The step kinds (what a step sends, what reply it accepts, how the reply is merged) are code, because they are the
  contract that keeps output valid.
- **Plan, then execute.** As in Kai: configuration resolves into a pure plan (the exact requests, their order and
  limits); a small executor performs it. Plans are testable without a network, and `apo plan` shows one before any
  paid call.
- **Every run can be replayed.** Requests are content-addressed; the reply to each is stored before it is used. A
  rerun with the same request hits the store instead of the model, so resuming, re-scoring, re-formatting, and
  testing cost nothing, and anyone given a run directory can reproduce its outputs offline.
- **Everything is bounded.** Every run has explicit limits: token caps per request, attempts per request, a timeout
  per call, and a budget per run. Paid calls need an explicit flag. Hitting a limit stops the run cleanly at a
  resumable point.
- **Assert assumptions.** Loosened [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md),
  as in Kai: check inputs at boundaries, fail loudly on violated invariants, prefer simple designs; "an hour or day
  of design is worth weeks or months in production".
- **Command line per [clig.dev](https://clig.dev/).** Human output on stderr, machine output (`--json`) on stdout,
  meaningful exit codes, no interactive prompts in non-interactive use.
- **Tests per matklad's [How to Test](https://matklad.github.io/2021/05/31/how-to-test.html):** data-driven checks
  through one `check` function per unit, and whole-run tests that replay recorded replies instead of calling models.

## Concepts

| Concept | Meaning | Defined in |
|---|---|---|
| Provider | An endpoint protocol plus where its key comes from | `providers.json` |
| Model | A provider plus a model ID and request options | `experiment.json` |
| Prompt | A template with named variables, identified by its hash | `prompts/*.md` |
| Step | One fixed step kind with its prompt, limits, and options | `pipeline.json` |
| Pipeline | Ordered steps over a dataset | `pipeline.json` |
| Dataset | CoNLL-U input plus its segmentation into passages | `dataset.json` |
| Experiment | Models × prompt variants × dataset, with a budget | `experiment.json` |
| Run | One model and prompt set executed over a dataset | run directory |
| Gold set | External reference data plus its pin and licence | `gold/*.json` |
| Metric | A scoring function from a run and a gold set | code, selected in `eval.json` |

## Commands

```text
apo validate <file.conllu>... [--profile <profile.json>]   check CoNLL-U; no models, no config needed
apo plan <experiment.json>                                 print the requests, cache hits, and cost estimate
apo run <experiment.json> [--paid] [--only <label>]        execute; resumes from the store
apo seed <experiment.json> --from <work-dir>               answer a run's calls from an existing work's outputs
apo gold fetch <gold.json>                                 download a gold set's files and check their SHA-256
apo eval <run-dir>... --gold <gold.json>                   score runs against a gold set
apo compare <run-dir>... --judge <judge.json> --out <dir>  blinded pairwise judgments and a ranking
apo compare <run-dir>... --export-preferences <sheet.tsv>  review sheets (also --export-mqm; --import-… to read them)
apo export <run-dir> <work-dir>                            a run as an archive work folder
apo adopt <work-dir>                                       a pre-apo work folder as a non-replayable run
```

## Configuration

All configuration is JSON; prompts are Markdown files. Paths are relative to the file that names them.

`providers.json`: protocols are code, endpoints are data.

```json
{
  "providers": {
    "openrouter": { "protocol": "openai-chat", "base_url": "https://openrouter.ai/api/v1", "key_env": "OPENROUTER_API_KEY" },
    "local":      { "protocol": "openai-chat", "base_url": "http://127.0.0.1:8080/v1" },
    "anthropic":  { "protocol": "anthropic-messages", "key_env": "ANTHROPIC_API_KEY" },
    "claude-cli": { "protocol": "claude-cli" }
  }
}
```

- `openai-chat` covers OpenRouter, PPQ, vLLM, llama.cpp, and Ollama, so open-weight models need no code.
- `anthropic-messages` adds prompt caching and the Batch API (half price) for runs that can wait.
- `claude-cli` runs `claude -p` on a local login, as Archeion's `subscription` backend does today.
- Keys are read only from the named environment variable, never from configuration files or run directories.

`prompts/gloss.md`: a template; `{{variables}}` are filled by the step kind, which documents the ones it provides.

`pipeline.json`:

```json
{
  "steps": [
    { "kind": "translate-sentence", "prompt": "prompts/translate.md", "max_tokens": 1024 },
    { "kind": "gloss-tokens",       "prompt": "prompts/gloss.md",     "max_tokens": 2048 },
    { "kind": "translate-passage",  "prompt": "prompts/passage.md",   "max_tokens": 1024 }
  ],
  "limits": { "attempts": 3, "timeout_seconds": 180 }
}
```

`experiment.json`:

```json
{
  "dataset": "dataset.json",
  "pipeline": "pipeline.json",
  "models": [
    { "name": "sonnet-5", "provider": "openrouter", "id": "anthropic/claude-sonnet-5" },
    { "name": "qwen-local", "provider": "local", "id": "qwen3.8-27b", "options": { "temperature": 0 } }
  ],
  "variants": { "context": ["prompts/context-a.md", "prompts/context-b.md"] },
  "budget_usd": 25
}
```

## Step kinds

Each step kind fixes four things: what the model sees, the reply schema, the checks a reply must pass, and how an
accepted reply is merged. The first three reproduce Archeion's current pipeline.

| Kind | Model sees | Reply | Checks | Merged as |
|---|---|---|---|---|
| `translate-sentence` | one sentence's real tokens; placeholder rows as ellipsis evidence | `{prose, literal}` | non-empty, single line | `# prose_translation`, `# literal_translation` |
| `gloss-tokens` | one sentence's real tokens and its translations | `{glosses: [{id, gloss}]}` | exactly the given IDs, no copied Greek form, no field separators | `gloss=` in MISC |
| `translate-passage` | a citation passage's rows without glosses, plus its sentences as context | `{prose, literal}` | as `translate-sentence` | `units.jsonl` |
| `align` (later) | a sentence and a reference translation | word-index pairs | indices in range | alignment sidecar |

A reply that fails its checks is retried up to the attempt limit, then the run stops at that item with the reply
kept for inspection.

## Run directory

The run directory is apo's only interface with the outside: consumers import it, `eval` and `compare` read it.

```text
<runs>/<experiment>/
  store/<hash>.json      each accepted request and reply, by the SHA-256 of the request; shared by the runs
  batch/                 batch results waiting to be checked
  <label>-<run-id>/
    manifest.json        apo version, run ID, model, dataset, steps, limits, status, cost; `replayable`
    config/              snapshot of every configuration file and prompt template used
    events.jsonl         one line per call: step, item, attempt, cache hit, tokens, cost, latency, outcome
    rejected/            replies that failed their checks, with the reason
    output/
      <dataset>.conllu   tokens with glosses and sentence translations
      units.jsonl        passage translations
      passages.jsonl     the passages covered, with their token IDs
      alignments.jsonl   alignment links per sentence
    eval/<gold>.json     scores written by apo eval
```

- `run-id` is a hash of everything that determines the outputs (model, rendered prompts, dataset, selected
  passages), so the same configuration always resumes the same run, and a changed prompt or model is a different
  run, never a mixed one.
- The store is shared by an experiment's runs: raising a limit or adding a step makes a new run that calls the model
  only for requests no run has made.
- Outputs are rebuilt from the store, so formatting changes never need model calls.
- `on_failure: "skip"` (for benchmarks) records an item that fails every attempt and continues; the default, `stop`,
  ends the run there so it can be resumed.

## Validator

`apo validate` checks CoNLL-U in two layers: the format (ten tab-separated columns, IDs, ranges, empty nodes,
heads forming a tree, `# sent_id` and `# text` handling) and a profile, a JSON file naming required comments and
MISC keys (for apo's output: `prose_translation`, `literal_translation`, `gloss=`). Its format checks are tested
against the official UD `validate.py` on the UD Ancient Greek treebanks, so a file it accepts is one the UD tools
accept. It is a separate module of the library, so other tools can use it without the runner.

## Evaluation

apo owns metrics, not gold data. A gold set is a pinned external download described by a small manifest (URL,
commit or version, SHA-256, licence, what it measures); apo fetches and checks it, and copies nothing into a
consumer's repository unless the licence allows it.

| Gold set | Measures | Metric | Notes |
|---|---|---|---|
| Ugarit Ancient Greek–English alignment gold standard (Yousef, Palladino et al.) | gloss layer | precision, recall, F1, alignment error rate; correct / partial / wrong as in Nadel & Crane (2025) | expert annotation, agreement above 80% |
| Berean Interlinear (New Testament) | gloss layer, at scale | match against accepted alternatives | one translator's choices; glosses Nestle 1904, so Westcott-Hort differences are matched and skipped |
| Public-domain translations (e.g. Long and Casaubon for Marcus Aurelius, Jowett and Fowler for Plato, the World English Bible) | translations | chrF with multiple references (COMET later) | alarms for regressions only; they correlate weakly with expert judgment |
| LSJ senses (later) | glosses | gloss within the lemma's senses | widens accepted alternatives |
| AGDT, PROIEL, and their UD versions (later) | morphology and syntax | LAS, MLAS, BLEX (CoNLL 2018) | only for steps that produce them, or to measure input annotation |

Words are matched to gold words within a passage by identical form first, then in order when both have the same
number of words, so editions that differ in word order or wording still compare the words they share. Every score
reports its coverage (passages and words compared, items failed).

Comparison (`apo compare`) turns subjective judgments into measurements:

- Blinded pairwise preference between runs, by a judge model or by human reviewers through exported sheets, with
  order randomized; rankings by Bradley–Terry.
- A judge model is from a different family than the models judged, and is checked against human judgments before its
  rankings are trusted.
- MQM-style error spans (mistranslation, omission, addition, terminology, fluency; with severity) for translations.
- Agreement between raters (Krippendorff's α) is reported with every human result, as the ceiling the models are
  measured against.
- Every report states cost, tokens, and latency next to quality.

## Layout

```text
package/          pure Roc library, published as a Roc package
  JsonValue.roc     bounded JSON codec; canonical encoding for request hashes
  Conllu.roc        parse and serialize CoNLL-U; comments and MISC items
  Validate.roc      format rules and profiles
  Template.roc      {{variable}} prompt templates
  Dataset.roc       datasets: token IDs, omitted rows, passages, line ranges
  Steps.roc         step kinds: request payloads, reply checks, merges
  Provider.roc      protocols: requests, replies, costs, batches
  Gold.roc          gold manifests and formats (Ugarit alignments, Berean glosses, JSONL)
  Metrics.roc       alignment, gloss, chrF, Bradley–Terry, Krippendorff's α, Cohen's κ, MQM
cli/              the apo command line and its effects (basic-cli 0.26)
  Load.roc          experiment -> runs; Execute.roc the store and calls; Evaluate.roc, Compare.roc, Archive.roc
tests/            a deterministic stand-in model and a whole-run fixture
examples/         gold manifests, validation profiles, experiments
docs/
Kaifile.roc       tasks, checks, and the development environment
```

The package has no effects; the CLI performs them. Dependencies are pinned, and vendored where practical.

## Relationship to Archeion

Archeion is the archive; apo is a tool it uses. Archeion keeps its prompts and one experiment per work in `apo/`
(they are provenance), and `apo export` writes finished runs into `conllu/generated/`. Release, sync, and deploy
stay in Archeion unchanged. Until apo publishes releases, Archeion runs it from a sibling checkout.

Archeion's existing works predate apo and kept no request and reply store. `apo seed` answers each call a run would
make from such a work's outputs (checked like any reply), so a work continues without regeneration; seeding
Archeion's Luke reproduces its 62 sentences and 80 passages exactly, and its prompts render byte-identical to
`loop.roc`'s. `apo adopt` instead wraps a work as a non-replayable run, for scoring it next to new runs.

## Milestones

1. **Validator.** `apo validate` with the format layer and a profile; checked against UD `validate.py`; Archeion's
   generated files pass under apo's output profile.
2. **Runner, one provider.** `apo plan` and `apo run` with `openai-chat` and the three Archeion step kinds; a small
   slice of an Archeion work produces output in Archeion's format; whole-run tests replay a recorded store.
3. **Import.** Archeion's existing works imported as store-less runs; Archeion generates new passages through apo.
4. **Evaluation.** Ugarit gold set and alignment metrics; two models scored on the same slice.
5. **Comparison.** Pairwise judging, Bradley–Terry ranking, review sheets, agreement.
6. **Cost.** `anthropic-messages` with prompt caching and batches; budget enforcement across providers.

All six are implemented. Not yet exercised against live services: `anthropic-messages` calls and batches (tested on
request building and reply parsing only).

## Open questions

- Berean Interlinear: the April 2023 public-domain dedication names "the Berean Bible and Majority Bible texts" and
  not the interlinear's glosses explicitly; the manifest says so.
- Ugarit's licence is CC BY-SA 4.0 in its repository but CC BY 4.0 on Zenodo; the manifest pins the repository.
- AGDT is CC BY-SA 3.0 US in its repository, but UD_Ancient_Greek-Perseus is CC BY-NC-SA 2.5.
- Which judge prompts and gold sets ship as defaults once apo is released.
