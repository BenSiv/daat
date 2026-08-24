# Prior Art

## What a system like this actually needs

The kind of system daat is meant to be is a knowledge-management platform for an organization's textual artifacts -- documents, notes, procedures, whatever an organization writes down -- built around a specific set of requirements:

1. **A wiki-style interface** for browsing and editing free-form textual content, with linking between pages.
2. **Full version history**: every change traceable, nothing silently overwritten, an actual audit trail rather than just a current snapshot.
3. **Configurability**: what gets tracked and how it's structured should be adaptable per deployment, not fixed by the platform itself.
4. **Easy extensibility and scriptability through an API**, so a deployment can add its own automation and integrations without forking the platform.
5. **One system, not two kept in sync**: structured, transactional records -- observations, samples, inventory, whatever a given deployment tracks day to day, i.e. a LIMS-style layer -- need to live under the same audit and access model as the textual knowledge base, not in a separate system that has to be reconciled with it by hand.
6. **AI-assisted retrieval and maintenance**: search that understands meaning, not just keywords, and an agent that can help update, distill, and connect content over time -- not a system that only serves static pages back to a human.
7. **Real, per-user authentication and authorization**, since none of the above means anything if a change can't be attributed to someone or access can't be restricted.

In practice, two of these turned out to be where almost every existing option fell short: 4 and 6. Very little existing wiki or knowledge-base software was built with an agent as a first-class actor in mind -- there's no natural place to hang something that reads, distills, and links content on its own, because nothing about the platform expected a caller other than a human clicking through pages. And "extensible" usually means "extensible by writing a plugin in the platform's own framework," not "scriptable against a small, stable API" -- a much higher floor for a deployment that just wants to automate one workflow. A handful of candidates also had a weak or entirely absent answer to 7, which undermines requirement 2 as well: a version history is only an audit trail if it's clear who made each change.

## Where general-purpose wikis and knowledge platforms fall short

### Minimal, file- or git-backed wikis

The lightest-weight category: a thin web app over Markdown files, with Git (or nothing) doing version control underneath.

- **Stack:** Ruby/Rack for one, Python/Flask for another, plain Python/Flask for a third -- each stores pages as flat Markdown files, two of the three using a Git repository as the actual history mechanism.
- **Strengths:** Genuinely simple to run, easy to read and export (the content is just files), low operational footprint, real Git-backed version history in the ones that use it.
- **Gaps:** Authentication ranges from real (per-user accounts, role-based read/write/upload/admin permissions, even SSO via a reverse proxy in the more complete one) to nonexistent (no built-in access control at all in the simplest one -- every editor is anonymous and equally privileged unless an external auth layer is bolted on afterward). None expose a documented API for programmatic access or a plugin system for extensions; one of them says as much directly, describing itself as minimalist by design rather than extensible. None have any concept of a structured, queryable entity (requirement 5) -- everything is a page of text, which is exactly the right shape for requirement 1 and exactly the wrong shape for requirement 5. None have any AI-native retrieval or maintenance built in, or an obvious place to add it.

### Full-featured general wiki platforms

Larger, older, far more capable software, built to serve very large, very general wikis.

- **Stack:** One is a mature PHP/MySQL application with its own templating and extension-hook system; another is a version-control system (written in C) with wiki pages and a ticket tracker built in on top of its own repository format, customized through a small embedded scripting language for skinning.
- **Strengths:** The PHP-based one has a genuinely strong, well-documented API (the same one that powers every bot and tool built against the platform's largest public deployments) and a mature, real permissions model down to the page and namespace level -- requirement 4's API half and requirement 7 are both handled well. The VCS-based one gets real version history essentially for free, since the wiki lives inside the same repository as everything else it tracks.
- **Gaps:** The PHP-based one has no structured-entity concept at all -- a page is a blob of wikitext, versioned as a whole, not as an auditable record with fields -- so requirement 5 would mean building a second system beside it, and it has no native AI retrieval or agent-facing hooks; extending it means writing a PHP extension against its own framework, not scripting against a stable API from the outside. The VCS-based one bundles wiki, tickets, and version control into one opinionated internal model that isn't meant to represent arbitrary structured entities either -- adding one means representing it as a special-cased wiki page or ticket rather than a first-class record -- and its embedded scripting language is built for lightweight skin/report customization, not for general extensibility or agent tool-calling. Both also tie the wiki's own identity and versioning model to the platform's specific repository or database format, which becomes its own constraint once the goal is one shared store for text and structured records together.

### Extending a version-control-based wiki directly

A natural next move, given how close the VCS-based wiki above already gets to requirement 2 for free: keep the underlying wiki/ticket engine, and build a scripting layer on top of it to add the rest -- structured entities, a nicer skin, an embedded chat agent, page-creation workflows tied to entity types.

- **Gaps found in practice:** The skinning layer's own scripting hooks are meant for small, declarative customizations (a header, a footer, a bit of injected markup), not for hosting real application logic -- pushed further than that, the generated configuration becomes an unstructured, hard-to-test blob rather than real code. The CGI process model (a gateway relaying into the underlying tool's own CLI per request) adds a layer of indirection that has to be worked around rather than configured, since the two processes don't share an environment as cleanly as a single application would. And the platform's own authentication model is closed enough that its password hashes and user records don't carry over to a different auth scheme, meaning even switching how users log in requires a parallel migration, not a config change. None of this is a fatal flaw in the underlying VCS-based wiki as a wiki -- it's what happens whenever a tool that wasn't built to host arbitrary application logic gets pushed to do exactly that.

### Purpose-built ELN/LIMS platforms

Software built specifically for laboratory/operational record-keeping rather than general wikis -- the natural place to look for requirement 5, on the assumption it might bring 1 along with it.

- **Stack:** One is a PHP application with real, versioned experiment/resource records and a documented REST API with third-party client libraries; the other is built on a general-purpose enterprise content-management application server (itself built on an even more general Python object-database/component framework), with a real workflow engine and immutable audit snapshots.
- **Strengths:** Both handle requirement 5 natively -- structured, auditable records are the whole point -- and both have genuinely strong authentication/authorization and audit trails (requirement 7 and the audit half of requirement 2), including one with a documented, actively-used API and a small ecosystem of third-party scripting clients.
- **Gaps:** Neither is built around free-form, wiki-style textual content as a first-class citizen (requirement 1) -- the closest either gets is a notebook entry or an experiment record, not a general page with backlinks and a folder tree meant to hold prose, procedures, and reference material. Neither has anything resembling requirement 6 out of the box -- no native semantic retrieval, no built-in mechanism for an agent to distill or re-link content over time -- and adding it means building a separate service against the API rather than something the platform's own data model was shaped to support. The one built on a general-purpose content-management framework in particular means every extension has to go through that framework's own object model and component architecture first, which is a real, separate thing to learn on top of the actual domain -- the same tax the general wiki platforms above charge, just from the LIMS side instead of the wiki side.

### Note-taking app plus an external pipeline

A different shape entirely: use a local-first note-taking tool as the textual knowledge store, and write a separate script or pipeline that pushes structured data into it as generated notes, or builds a retrieval index alongside it.

- **Strengths:** The note-taking side genuinely nails requirement 1 -- fast linking, a real page-per-topic model, a good editing experience -- and a pipeline can add whatever retrieval or embedding logic requirement 6 needs, since it's just a script with no platform to work around.
- **Gaps:** This is requirement 5's "kept in sync by hand" problem in its purest form: the vault and the structured data live in two different systems, connected by a pipeline that has to be re-run and can drift out of date the moment either side changes independently. There's no shared, per-user authentication or access control (requirement 7) -- these tools are built for a single local user, not a multi-user server -- and no shared version history spanning both halves (requirement 2 only covers whichever half happens to be under its own version control, not the relationship between them).

## The common shape of the gap

Nothing above is a story about any one of these being poorly built. Each is good at what it was actually built for -- a wiki, a version-control system, a lab notebook, a personal knowledge vault. The gap is structural: general-purpose software carries the surface area needed to support many different deployments, and neither "an agent as a first-class actor" nor "a small, stable, single-language API surface instead of a framework-specific plugin system" was ever part of what most of it was built to be extensible for. Bolting either on afterward means fighting the base's own architecture rather than using it, which is the same shape of problem however capable the base otherwise is. See [doc/why-luam.md](why-luam.md) for how the implementation language carries the same discipline -- minimal surface area, one way to do a thing -- down to the level daat is actually written in.
