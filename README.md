# apo

apo (ἀπό, "from") glosses and translates Ancient Greek with language models. Give it annotated text (CoNLL-U, as in
[Opera Graeca Adnotata](https://github.com/OperaGraecaAdnotata/OGA)) and a model; for every sentence it writes a prose
translation and a contextual gloss for every word, and for every citation passage (a verse, a section) a passage
translation. The model never writes the file: it returns small JSON answers that apo checks and merges.

Design: [docs/design.md](docs/design.md).

## Build

apo is written in Roc and built with [Kai](https://github.com/thebrandonlucas/kai):

```sh
kai run build        # ./apo
kai run test         # the package's checks
kai workflow e2e     # a whole run with a stand-in model, compared with expected outputs
```

## Use

```sh
apo init                       # provider, models, works and output folders → ~/.config/apo/config.json
apo run --count 5              # the next 5 sentences of every work, with every model
apo run --work luke --model sonnet --count 20
```

`init` shows a list of providers (type to filter, arrows to move, Enter to choose) and then the models that provider
offers, and takes options outside a terminal (`apo init --help`).

### Providers

- **Hosted APIs:** Anthropic, OpenAI, OpenRouter, PPQ, Google, Groq and about 200 more, by API key.
- **Local models:** Ollama, llama.cpp, LM Studio, vLLM, or any OpenAI-compatible server by URL, on your machine or a
  cluster: `apo init --base-url http://gpu-node:8000/v1 --model <id>`. Start the server first; apo lists its models.
  apo rejects replies that are not the JSON it asked for, so a small model may fail every sentence. If a model wraps
  its JSON in prose, add `"options": { "response_format": { "type": "json_object" } }` to it in `config.json` (tested
  with Ollama; support varies by server).
- **Your Claude Code login:** `claude -p`, through the unmodified Claude Code. Anthropic does not allow other tools to
  sign in with a Claude subscription, so apo has no such login; use an API key for large runs.

```sh
apo login openrouter     # stores the key, hidden as you type or read from standard input
apo logout openrouter
```

Keys are kept in `~/.local/share/apo/auth.json`, readable only by you, never in `config.json`, so a configuration can
be shared. A stored key is used before the provider's environment variable (`OPENROUTER_API_KEY`), which also works
alone.

### Works

```text
works/
  luke.conllu         one work per CoNLL-U file
  luke.context.md     optional: guidance for this work; a first line "# <Title>" sets its title
  luke.refs.tsv       optional: "token<TAB>citation" lines, for passage translations
```

To use Opera Graeca Adnotata, link the texts you want; a folder of all 1,999 would run on every one:

```sh
mkdir works
ln -s /path/to/OGA/workspace/conllu/tlg0031.tlg003.perseus-grc2.tok01_sentence-seg01_annotated_lemma.conllu works/luke.conllu
```

OGA's conventions are recognized: its token IDs (`t_N`, the first MISC item) and its rows for elided words (`e_…`),
which the model sees as evidence of ellipsis but never glosses. Without a `refs.tsv`, apo translates and glosses
sentences only.

### Output

```text
apo-output/luke/sonnet/
  output.conllu     the source rows untouched, plus a prose translation per sentence and gloss= in MISC
  units.jsonl       passage translations (with refs.tsv)
  replies.jsonl     every accepted reply, by the SHA-256 of its request
```

`run` resumes: a sentence whose replies are in `replies.jsonl` is not called again, so rerunning or raising `--count`
costs only the new sentences. If a work's output was made with a different model, prompt, context or limit, `run`
stops rather than mix the two; `--fresh` starts that work over.

## Status

Version 0.1.0, not yet released.

## Credits

`providers.json` is drawn from [models.dev](https://models.dev) (MIT License, Copyright (c) 2025 models.dev).
