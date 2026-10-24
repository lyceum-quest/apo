# apo

apo (ἀπό, "from") derives annotated text from source corpora with language models, and measures how good it is.
Describe models, prompts and steps in JSON; apo runs them over CoNLL-U, checks every reply, writes standard
CoNLL-U, and scores and compares runs against external gold data. Nothing in it names a model, provider or corpus.

Design: [docs/design.md](docs/design.md).

## Build

apo is written in Roc and built with [Kai](https://github.com/thebrandonlucas/kai):

```sh
kai run build        # ./apo
kai run test         # the package's checks
kai workflow e2e     # a whole run with a stand-in model, compared with expected outputs
```

## Commands

```text
apo validate <file.conllu>... [--profile <profile.json>]   check CoNLL-U (UD format rules, plus a profile's)
apo plan <experiment.json>                                 the calls a run would make, what is stored, the cost
apo run <experiment.json> [--paid] [--only <label>]        run every model and prompt variant; resumes for free
apo seed <experiment.json> --from <work-dir>               answer a run's calls from an existing work's outputs
apo gold fetch <gold.json>                                 download a gold set and check its SHA-256
apo eval <run-dir>... --gold <gold.json>                   score runs against a gold set
apo compare <run-dir>... --judge <judge.json> --out <dir>  rank runs by blinded pairwise preference
apo compare <run-dir>... --export-preferences <sheet.tsv>  the same, by reviewers (also --export-mqm)
apo export <run-dir> <work-dir>                            write a run as an archive work folder
apo adopt <work-dir>                                       wrap a work made before apo as a (non-replayable) run
```

## An experiment

```text
experiment.json   models × prompt variants × dataset, with a budget
providers.json    endpoints: openai-chat (OpenRouter, PPQ, vLLM, llama.cpp, Ollama), anthropic-messages (with
                  prompt caching; "batch": true for the half-price Batch API), claude-cli, or any command
pipeline.json     steps: translate-sentence, gloss-tokens, translate-passage, align; limits; on_failure
dataset.json      CoNLL-U or tokenized input (or a gold set's files), token IDs, omitted rows, passages
prompts/*.md      templates with {{variables}}
```

Each run's directory holds its manifest, a snapshot of its configuration, an event log (one line per call: tokens,
cost, latency, outcome), rejected replies, and its outputs. Accepted replies are stored once per experiment,
keyed by the SHA-256 of the request, so rerunning, raising a limit, or adding a step calls the model only for what
is new, and anyone with the run can reproduce its outputs offline. Paid providers need `--paid`; a run stops at its
budget.

`examples/` has the gold manifests (Ugarit alignments, Berean Interlinear glosses), validation profiles, and two
experiments over the Crito part of the Ugarit gold standard.

## Status

Version 0.1.0, not yet released.

- Validation agrees with UD's `validate.py` (levels 1–2) on the UD Ancient Greek Perseus test set, Archeion's files,
  and injected errors. Not checked: Unicode normalization, `# text` against forms, enhanced-graph connectivity.
- The `anthropic-messages` protocol and batches are tested on request building and reply parsing only; no live
  call has been made through them.
- COMET is not built in; chrF is, and only as a regression signal.
