# DAAT

A self-maintaining knowledge base with a built-in AI agent. Documents, chat conversations and the agent's own work sit in one shared pool that tiers, links and distills itself as it is retrieved and edited: no curator, no separate note-taking system to keep in sync. Records of your own types (samples, experiments, anything) live alongside it with a full audit history. It is a single, self-contained web application written in [Luam](https://github.com/BenSiv/luam): its own logins, rendering and storage.

## What's inside

- **Knowledge pool**: usage-driven tiers, a fixed heat budget, distillation and agent-judged links between documents. See [architecture.md](doc/architecture.md) ("Knowledge pool") and [tier-curation-ladder.md](doc/tier-curation-ladder.md).
- **Documents and tags**: a document tree in Markdown with `[[title]]` links, semantic search, and tags the data defines and the agent maintains. See [document-link-flow.md](doc/document-link-flow.md) and [tag-ontology.md](doc/tag-ontology.md).
- **Chat agent**: an owned turn loop with tools, an approval gate on every change to data, context compaction, and the exact prompt and token counts of every model call stored for audit. See [agent-harness-rationale.md](doc/agent-harness-rationale.md) and [agent-protocol.md](doc/agent-protocol.md).
- **Entity types and extensions**: record types defined as data, extensions and saved views behind admin approval, and a JSON API. See [schema.md](doc/schema.md), [extensibility.md](doc/extensibility.md) and [api.md](doc/api.md).
- **Auth and traceability**: accounts, sessions and capabilities checked on every request; nothing is ever deleted, only archived. See [auth.md](doc/auth.md).

## Building

Requires a built `luam` checkout beside this one (`../luam`, or set `LUAM_DIR`), and `cmark-gfm` on `PATH` at runtime.

```sh
./bld/build.sh          # -> bin/daat
```

The chat agent's model provider is chosen in `platform.lua` (`agent_provider`): Google Vertex AI (chat and embeddings, needs `vertex_project`), Claude (chat only), or a scripted test provider. Vertex authenticates through the VM's service account on Google Cloud, or the logged-in `gcloud` account elsewhere.

## Testing

Requires `bats` on `PATH`.

```sh
./bld/test.sh                   # unit and integration tests, plus the agent scorecard in test mode
./bld/eval.sh --mode live       # the agent scorecard against a real model
```

Live runs need `DAAT_EVAL_VERTEX_PROJECT`. See [agent-eval.md](doc/agent-eval.md) for the scorecard and its demo-lab deployment.

## Usage

```sh
daat init                       # create the store in the current directory
daat                            # list the command groups; most print their usage when run alone
```

Run as a CGI program under a web server, it serves the web application instead (see `src/main.lua`). [dev/demo/](dev/demo/README.md) builds the demo lab into a container image that runs as a live instance.

## Contributing

Start with [onboarding.md](doc/onboarding.md): prerequisites, repository layout, an architecture primer and a one-command dev container. Open work is tracked in [GitHub issues](https://github.com/BenSiv/daat/issues). Terms are defined in [glossary.md](doc/glossary.md), and [why-luam.md](doc/why-luam.md) and [prior-art.md](doc/prior-art.md) explain the project's choices.
