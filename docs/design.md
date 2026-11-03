# apo design

apo (ἀπό, "from") glosses and translates Ancient Greek with language models. It reads annotated CoNLL-U, asks a
model for a prose translation of each sentence and a contextual gloss of each word, then a translation of each
citation passage, checks every reply, and writes CoNLL-U. It is deliberately small: the parts that make the results
good, and nothing that only measures them.

## Principles

- **The tool owns structure; the model owns meaning.** Token IDs, sentence identity, row order, and serialization
  are never model output. A model returns a small patch (glosses keyed by the IDs it was given, or a translation
  string), apo checks it, and apo writes the file. Earlier experiments showed models dropping and renumbering rows
  whenever they were allowed to own the format.
- **Translate, then gloss.** The gloss step sees the sentence's translation, so each gloss is the word's
  contribution to that reading.
- **Ellipsis is evidence, not text.** Rows a corpus inserts for elided words (OGA's `e_…`) are shown to the model
  separately and never glossed.
- **Nothing is paid for twice.** Every accepted reply is kept, keyed by its request, before it is used. A rerun
  calls the model only for what is new, and outputs are rebuilt from replies whose requests match the current
  configuration, so a run never mixes outputs from different prompts or models.
- **Everything is bounded.** Token caps per request, attempts per reply, a timeout per call, and `--count` sentences
  per run.
- **Assert assumptions.** Loosened [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md):
  check inputs at boundaries (an unknown configuration key is an error), fail loudly, prefer simple designs.
- **Command line per [clig.dev](https://clig.dev/).** Progress on stderr, results on stdout, meaningful exit codes,
  questions only when standard input is a terminal.
- **Tests per matklad's [How to Test](https://matklad.github.io/2021/05/31/how-to-test.html):** data-driven checks
  in each module, and a whole run through a deterministic stand-in model.

## Commands

```text
apo init [options]    write the configuration; asks in a terminal, takes options otherwise
apo run [options]     the next --count sentences (default 10) of every work with every model
```

## Configuration

`config.json`, at `--config`, `$APO_CONFIG`, `$XDG_CONFIG_HOME/apo/config.json`, or `~/.config/apo/config.json`.
Paths are relative to its folder (`init` writes absolute ones).

```json
{
  "providers": {
    "openrouter": { "protocol": "openai-chat", "base_url": "https://openrouter.ai/api/v1", "key_env": "OPENROUTER_API_KEY" },
    "claude": { "protocol": "claude-cli" }
  },
  "models": [
    { "name": "sonnet", "provider": "claude", "id": "sonnet" }
  ],
  "works_dir": "works",
  "output_dir": "apo-output",
  "prompts_dir": "prompts",
  "limits": { "attempts": 3, "timeout_seconds": 180, "max_tokens": { "translate": 1024, "gloss": 2048, "passage": 1024 } },
  "author": { "name": "", "email": "" },
  "works": { "luke": { "label_separator": ":" } }
}
```

- Protocols: `openai-chat` (OpenRouter, PPQ, vLLM, llama.cpp, Ollama), `claude-cli` (`claude -p` on the local Claude
  Code login), and `command` (any program: the call as JSON on stdin, `{ "content" }` on stdout; the tests' stand-in
  model uses it). Keys come from `apo login` (`auth.json`, owner-only) or the environment variable `key_env` names, never `config.json`.
- `options` on a model are merged into each request (e.g. `temperature`).
- `prompts_dir` overrides the built-in prompts (`prompts/translate.md`, `gloss.md`, `passage.md`) file by file.
  Templates may use `{{title}}` and `{{context}}`.
- `works.<name>.label_separator` sets how a work's citation labels join their parts (`1.1` or `1:1`).

## Works

```text
<works_dir>/<name>.conllu       required
<works_dir>/<name>.context.md   optional; "# <Title>" on its first line sets {{title}}, the rest is {{context}}
<works_dir>/<name>.refs.tsv     optional; token<TAB>citation lines
```

Token IDs are OGA's `t_N` (the first MISC item) when the first word has one, else `<sentence>:<id>`. With OGA IDs,
rows whose MISC starts with `e_` are omitted structure; so are multiword ranges and empty nodes. Consecutive tokens
with the same citation form a passage; a passage is translated once all its sentences are done.

## Steps

| Step | Model sees | Reply | Checks | Merged as |
|---|---|---|---|---|
| translate a sentence | the sentence's real tokens; omitted rows as ellipsis evidence | `{prose_translation}` | non-empty, single line | `# prose_translation` |
| gloss its tokens | the sentence's real tokens and its translation | `{glosses: [{id, gloss}]}` | exactly the given IDs, no copied Greek form, no field separators | `gloss=` in MISC |
| translate a passage | the passage's rows without glosses, plus its sentences and their translations | `{prose_translation}` | as above | `units.jsonl` |

Every token is sent with all ten CoNLL-U columns. A reply that fails its checks is retried up to `limits.attempts`;
then the run stops with the reason and the reply's start.

## Output

```text
<output_dir>/<work>/<model>/
  output.conllu    the done sentences, in order
  units.jsonl      {ref, label, tokens, prose} per finished passage (works with citations)
  replies.jsonl    {step, item, request_sha256, content, input_tokens, output_tokens} per accepted reply
```

`output.conllu` keeps every source row and comment. It adds `# sentence_id`, `# translation_lang`,
`# prose_translation`, and `gloss=` in MISC; `# sent_id` and `# text` where the source has none; and, before the
first sentence, `# newdoc id`, `# generator`, `# model`, `# config_sha256` (a hash of the model, prompts and limits
that made it), and `# generated_by` when the configuration names an author.

A request's hash covers the protocol, endpoint, model ID and options, both messages, and the token cap. `run`
compares the output's `config_sha256` with the configuration before doing anything, and stops on a difference unless
`--fresh`.

## Layout

```text
package/          pure Roc library
  JsonValue.roc     bounded JSON codec; canonical encoding for request hashes
  Conllu.roc        parse and serialize CoNLL-U; comments and MISC items
  Config.roc        config.json, checked key by key
  Dataset.roc       token IDs, omitted rows, citation passages
  Steps.roc         requests, reply checks, merges
  Provider.roc      protocols: requests and replies
  Template.roc      {{variable}} prompt templates
cli/              the apo command line and its effects (basic-cli 0.26)
  main.roc          init and run
  Load.roc          configuration and works into jobs
  Execute.roc       the sentence loop, the reply cache, outputs
  Io.roc            files, hashing, environment
prompts/          the built-in prompts
tests/            a deterministic stand-in model and a whole-run fixture
```

## Later

Measuring and comparing models (gold sets, judge models, review sheets), validation profiles, archive import and
export, the Anthropic Messages API with batches, and budgets were removed to keep apo small; they are in the history
at tag `full-0.1.0`.
