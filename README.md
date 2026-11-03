# apo

See [blog post]()

**A**gent **P**rose **O**rchestrator, or `apo` (Greek ἀπό, meaning "from") uses LLMs to generate contextual glosses and prose translations for Ancient Greek. Using [Opera Graeca Adnotata](https://github.com/OperaGraecaAdnotata/OGA) CoNLL-U as a base, it takes config files which specify how agents should generate translations, then runs them to create the resulting translations!

You can specify how much to generate, compare results across different models, and set parameters for each translation run. By the end you'll have a prose translation for every verse and a contextual gloss for each word.

See more: [docs/design.md](docs/design.md).

## Build

apo is written in Roc and built with [Kai](https://github.com/thebrandonlucas/kai):

```sh
kai run build        # ./apo
kai run test         # the package's checks
kai workflow e2e     # a whole run with a stand-in model, compared with expected outputs
```

## Use

You need a `./works` folder with at least one input CoNLL-U to operate on, then:

```sh
apo init                       # provider, models, works and output folders → ~/.config/apo/config.json
apo run --count 5              # the next 5 sentences of every work, with every model
apo run --work luke --model sonnet --count 20
```

## Credits

`providers.json` is drawn from [models.dev](https://models.dev) (MIT License, Copyright (c) 2025 models.dev).
