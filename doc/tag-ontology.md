# Tag ontology: tags the data defines and the agent maintains

Status: proposal 2026-10-02 (Ben), revised 2026-10-04; tag upkeep in core done 2026-10-14. Builds on [structure-layers.md](structure-layers.md)'s tags. Tags were applied by an outside batch job (`cluster_tags.py` in the deployment's own repo) until 2026-10-14; daat now keeps them itself -- placement, restructuring and a cold start -- and the job is retired.

Today a tag is a flat cluster label: a hand-picked count (`k`) and a one-off name. The goal: the data decides how many tags there are and how they nest, the agent names, describes and relates them, and the user mostly just sees them, the same way tiers, distillation and connections already maintain themselves through usage. A user shouldn't need to know how any of it works, and the UI shouldn't grow to expose it.

## Three concepts, one word each

| | Folder | `[[link]]` | `#tag` |
|---|---|---|---|
| Answers | where does it live? | what does it point to? | what is it about? |
| Per document | exactly one | any number | a few |
| Set by | a person, by hand | a person or the agent, in the text | mostly automatic; a person can add one in the text |
| Shown as | the explorer tree | lines in the graph | colours in the graph, chips on a document |

These never stand in for each other. A folder is placement only and nothing infers meaning from it ([structure-layers.md](structure-layers.md)). A link is an edge between two documents. A tag is a subject on a group of documents: never a document, never a node, never an edge, and never written into a document's text by the system. Tags never look like folders: there's no tag tree to browse and no path syntax.

The user-facing word is **tag**, nothing else. A tag can have a broader tag ("Cocoa › Fermentation"); there's no second word for that ("subject", "group", "level", "cluster" are internal).

## What the user sees and does

- **On a document:** its tags as chips, a broader tag before it when there is one ("Cocoa › Fermentation"). A chip opens the tag.
- **A tag's page:** its description, its documents, and "see also" tags. Actions: rename, edit the description. That's all.
- **Tags page:** the list of tags, grouped under their broader tags, with document counts. A list, not an explorer.
- **Graph:** colour by tag (the broader tag) or by sub-tag; the legend hides and shows tags (built).
- **In the text:** `#tag` adds a tag to a document, as `[[link]]` adds a link (below).
- **In chat:** the agent can answer by tag ("what do we have on fermentation?"). When it thinks two tags are the same, or one covers two unrelated things, it says so in chat and asks, through the same approval as any other change it proposes.

Nothing else is user-facing: no recompute button, no proposals queue, no scores or plan reviews. An admin sees them through the CLI and the ledger: every split, merge and rename is an ordinary entity write.

### `#tag` in text

- **Syntax:** `#` then a letter, then letters, digits, `-` or `_` (`#fermentation`, `#cocoa-butter`); a tag whose name has spaces is written with `-` (`#cocoa-bean-fermentation` = "Cocoa bean fermentation"). Not a tag: headings (`# Title`), code, URL fragments (`page#section`), `#123`, a spreadsheet's `#REF!`/`#NAME?`, text inside `[[...]]`. No `#a/b` paths: how tags nest is the system's job, and a path would look like a folder.
- **On save,** next to `document.sync_links`: each `#tag` a person writes becomes a membership they asserted (`decision = pinned`, `via = text`); deleting it from the text removes it. An unknown tag is created. Only a person's write counts, and on an edit only the `#tags` it added: text a program copied in (an import, a sync) isn't anyone asserting a tag.
- **It holds while it's in the text:** recomputes never remove it, and it wins over a removal elsewhere.
- **Shown** as a chip, never a link.
- The agent may write `#tags` in documents it writes, through the same approval as the rest of the write.

## What runs on its own

- **Tags and how they nest**, from the data (below), kept up incrementally: a new or edited document joins its nearest tag on save, a tag that loosens splits, two that converge merge. No batch recompute, no schedule, no request.
- **Names and descriptions,** by the agent, when a tag is new or its documents changed.
- **"See also" tags,** by the agent, on pairs the data suggests.
- **A person's change always wins:** a renamed tag keeps its name, an edited description isn't overwritten, a `#tag` in the text stays, and a document a person removed from a tag isn't put back.

## Internals

### The data decides the shape

No fixed `k`, no fixed depth, and no batch job: daat keeps tags up from its own cached embeddings (`document_embedding`), in Luam, with no new dependency.

1. **A tag is a running summary:** its member count and the sum of its members' vectors, so its centre is always current.
2. **On save:** a new or edited document joins the nearest centre (one pass over the tags, about 1 ms). A person's `pinned`/`excluded` memberships and `#tags` in the text are never moved.
3. **Restructuring is local:** when a tag's spread grows past what it had when built, it splits in two (2-means over its own members); when two centres come closer than any two tags were when built, they merge. Thresholds are relative to the pool, never fixed cosines (a fixed 0.92 merged 32 tags into 18 in the 2026-10-04 check).
4. **Broader tags** (Ben, 2026-10-29, reversing 2026-10-12: 50 tags were too many to see, and the clustering shouldn't change for it): `daat tag broaden [--dry-run] [--replace]` (`src/tag_broader.lua`) groups the specific tags into a few broad ones, `tag.source = 'broader'`, each specific tag pointing to its broad tag through `tag.parent`. One agent call gets every tag (label and description) and puts each in a subject area it names, 5-12 areas -- literature, protocols, data and meeting notes on the same subject together. A tag it leaves out joins the area whose tags' centred centres are nearest its own. (2026-10-30: grouping by document similarity followed kind of document -- literature, protocols, internal records -- and, given that grouping as a start, the agent only renamed it; Ben wanted subjects.) A broad tag holds no documents and has no centre, so placement never puts a document in one; a person's own nesting (a parent that isn't a broad tag) is left alone. The graph's "Colour by tag" colours by the broad tag, "Colour by sub-tag" by the specific one. After `tag build --replace`, run `tag broaden --replace` again.
   **Definitions as records** (`daat tag define [--dry-run] [--limit N]`, `src/tag_define.lua`): one definition per tag, broad and specific, written as the ontology plan asks -- the broader tag as genus, then what sets it apart from its siblings -- from the tag's label, description, broader tag, siblings and most central documents (a broad tag: its sub-tags); checked by a second call; kept as a tier-3 record (`source_ref = 'tag:<id>'`, titled `Definition: <label>`). It's rewritten in place only when the tag's place in the hierarchy changes (`knowledge_tag_definition` keeps the hash), not when documents come and go, and archived with its tag.
5. **Stable names:** a tag keeps its name while its members mostly stay; a split's larger half keeps it.
6. **First build:** mini-batch k-means in queued chunks (about 0.25 s per 256 documents in Luam), so no long-running process is needed even for a new deployment.

Measured on 6,534 documents before writing any Luam (deployment check `incremental_tags_check.py`): held-out documents join one of their own tags by nearest centre 91% of the time (84% for the newest fifth); clustering daat's vectors agrees with the batch job's tags at adjusted Rand 0.46, against 0.62 between two seeds of the same batch method; half the pool streamed in with split/merge agrees with a full batch at 0.49. Cutting vectors to 256 dimensions costs about a point, and makes every step about 3x cheaper. If Luam is ever too slow, the fallback is a small C vector module in Luam's `lib/` (bound like `bcrypt`; the same pass runs 38x faster), not an outside runtime.

### Evidence between tags

Relations between tags are derived from tags and from the edges between their documents, not read from content: the tag-level graph is the edges between documents lifted onto their tags, compared with what the tags' own totals predict (lift, shrunk towards 1 on little evidence). `tag_evidence` (`tag_a`, `tag_b`, `kind`, `direction`, `weight`, `support`, `producer`) holds it, one row per pair, kind and producer, with raw totals only (lift is computed on read, so a row changes only when its edges do):

- **Core kinds:** `link` (`[[links]]`, directed) and `connection` (connection documents), recomputed from links and memberships when read and changed.
- **References:** a reference is an implicit link from a document to an entity -- the entity's name in running text. Core recognises them generically on save into `document_mention` (document, entity type, entity id), derived only from content like `document_link`: case-insensitive tokens, spacing and separators ignored ("Exp 185" is `Exp185`), every match kept (so a sample's name, which contains its experiment's, yields both). A name counts only if it's distinctive -- 4+ characters, a letter, and a digit or inner punctuation -- and names exactly one entity; that drops products called "A", a medium called "error", "Water". Deployment config adds aliases ("Experiment N" for `ExpN`). Evidence is two documents pointing at the same target, one kind per referenced entity type; the same rule counts two documents linking the same page. Measured on about 6,400 prod documents (deployment check `reference_match_check.py`): 98% of media and 93% of experiments that hand-written patterns found, with tag-pair lifts correlating at r = 0.96. Entity-to-entity edges (a sample's `source`) are already core data, read through the schema.
- **Extension kinds:** an extension may still write its own kinds through ordinary entity writes; like `document` content, the rows are domain-specific and core never interprets them: `kind` is an open string, and core never branches on its value.
- **Kinds are scored apart and never summed:** each kind's own lift, combined by geometric mean, so a kind with thousands of edges can't outweigh one with dozens. A producer with high-volume edges collapses them first (one unit per underlying thing, minimum support), and evidence is never drawn as graph edges.

### The agent describes and relates

Model calls only for judgment, each memoized on a hash of the tag's documents so an unchanged tag is never re-asked (as `document_tier_judgment` does for tiers): a name (a broader tag from its sub-tags' names); a description (`tag.description`); "see also" judgments on candidate pairs (tags in different branches with close centres, shared second-best memberships, or many links between their documents), yes or no with a reason, like the co-retrieval link judgment; and merge or split suggestions, raised in chat for approval. A suggestion a person declines isn't raised again unless the tags' documents change. Additive work happens automatically, as distillation does.

### Provenance and evidence

Kept in the data, not shown as such (after open-ontologies' [decision 0001](https://github.com/fabio-rovai/open-ontologies/blob/main/docs/decisions/0001-an-inference-is-not-an-assertion.md), an inference is not an assertion): "see also" between tags lives in `tag_relation`, apart from content and document links, with the same `decision` words as `document_tag` (`computed` proposed from evidence or by the agent, `pinned` asserted by a person, `excluded` rejected by a person and never proposed again), a `reason` in words and the `evidence` it came from. Broader is `tag.parent`, never a relation row, so there's one place for it. Each tag, membership and relation records whether it was computed from the data, judged by the agent, or set by a person (person over agent over data), plus enough evidence to check it: central documents and terms, the jump that made a level, a pair's scores, the documents the agent's reason cites.

### Lifecycle

After open-ontologies' [lifecycle](https://github.com/fabio-rovai/open-ontologies/blob/main/docs/lifecycle.md), adapted to incremental upkeep: every structural change (a split, a merge, a rename, a new broader tag, a relation) is an ordinary entity write, ledgered with the evidence that made it; anything a person set is locked; nothing is deleted (dropped memberships and tags are archived), so an admin can roll any change back; and a dry-run CLI reports what upkeep would change right now, for review before trusting a new threshold.

### Where it runs

One rule decides placement:

| | Continuous, driven by usage | One-time or scheduled batch |
|---|---|---|
| **Generic** | daat core | -- (nothing left here once clustering moves into core) |
| **Deployment-specific** | a daat extension | the deployment's own scripts |

- **Core:** the schema (`tag`, `document_tag`, `tag_relation`, `tag_evidence`), tag upkeep on save, `#tag` sync, core evidence kinds, the agent's judgment during retrieval review (memoized like tier and link reviews), the UI, agent tools and the SKOS export.
- **Extension / config:** aliases for references to the deployment's entity types (config), its own context for the agent's naming prompts; an extension only for evidence that isn't a reference or a link.
- **Deployment scripts:** one-time backfills and labelled checks of evidence thresholds. The outside batch job is retired (2026-10-14): the cold-start dry run on prod chose 38 tags, each mapping onto one of the job's 30 (adjusted Rand 0.51 against them; the job agreed with itself at 0.62-0.77 between runs), and Ben kept the 30 for daat to maintain rather than rebuild.

## Phases

1. **Done:** `tag.parent`; graph colours by tag or sub-tag (daat e7f8eb8).
2. **Done:** `tag_relation` (`tag_a`, `tag_b`, `decision` computed/pinned/excluded, `score`, `reason`, `evidence`), `tag_evidence` (`tag_a`, `tag_b`, `kind`, `direction`, `weight`, `support`, `producer`), `tag.description` as the tag's definition. Broader isn't a relation: it stays `tag.parent`, so there's one place for it.
3. **Tag upkeep in core.** *Done (3a):* running centres in `tag_centre` (`src/tag.lua`), kept in step with `document_tag` by its hooks whoever writes it; a new or edited document joins its nearest tag on save (plus a second within `tag_second_within`); `daat repair tags` rebuilds centres or re-places one document. A deployment that already has tags runs `daat repair tags` once to build the centres; until then placement does nothing. *Done (3b, 2026-10-07):* split, merge and label checks in `src/tag_upkeep.lua` -- the data proposes, the agent decides (Ben: no mechanical names; every change is judged on the documents). Spread from the running summary alone (1 - |sum| / members). A split is proposed when a tag's spread passes its built spread by 15% (and it has `tag_split_min`, default 40, members); 2-means with deterministic seeds gives two halves, and the agent answers SAME (one subject: nothing moves, the looser spread becomes its baseline) or DIFFERENT (it names both halves, keeping the label where it still fits). Tags are compared by their centred centres -- each centre less the pool's average, which the running summaries give (every tag's sum over all their members): in daat's vectors every document of one field shares a large common direction, so raw centres all sit close (prod 2026-10-11: median pair 0.81, closest 0.97) while 92% of documents are still nearest their own tag; centred, the median pair is -0.07 and only real overlaps stay close (the three media-preparation tags, 0.77-0.89, merged by hand into one). A merge is proposed when two centred centres are closer than any two were at build; the agent answers SAME (merged into the larger, named for the whole, the other archived) or DIFFERENT (kept apart, not re-asked until the tags' members change by 10%). A label check is proposed when a tag's members changed by 20% since its label was last judged -- grown or shrunk (2026-10-15: a tag whose meeting notes moved elsewhere kept "R&D Meeting Notes" over what was left); the agent answers FITS or RENAME with a new label and description. Manual tags take no part; pinned memberships never move; a label another tag has isn't applied; at most five agent calls a run. Baselines in `tag_upkeep`/`system_state`, set by `daat repair tags`; verdicts in `tag_judgment`. Runs after `daat document embed-pending` embeds anything when `tag_restructure` is on (default off); `daat repair tags --restructure [--dry-run [--judge]]` by hand; `daat tag merge <into> <from>... [--label] [--description]` for a person's own merge (moves pinned memberships too); `--dry-run --judge --pairs-above <cosine>` asks the agent about every pair of tags above a cosine, writing nothing -- for tags built elsewhere (the outside job's), whose closest pair can sit so close in daat's vectors (0.974 in prod, 2026-10-07) that the build baseline would never propose a merge. The broader level is left out (Ben, 2026-10-12). *Built (3c, 2026-10-12):* the cold start, `src/tag_build.lua` -- `daat tag build [--dry-run [--name]]`. Vectors with the pool's average removed; spherical k-means into ~sqrt(n) micro-clusters (at most 150, as `cluster_tags.py`) from a fixed seed; a consensus of 10 more k-means runs on 80% resamples (k from half to twice the micro count) gives, for each pair of micro-clusters, the share of their documents' pairs put together -- evidence accumulation as `cluster_tags.py --tree`, but over micro-clusters, since an n x n matrix doesn't fit Luam; average linkage over 1 - that share, cut where a level lives longest (a tie to the coarser) within 15-60 tags -- the floor scaled down for a small pool, a tag per 60 documents; documents with under `tag_min_text` (200) characters of their own text left out -- folder pages, experiment-view templates and files with no text made four "tags" of their own in prod's dry run (2026-10-13) -- and placement on save skips them too (`document_embedding.body_chars`); tags under 10 documents dissolved; every document to its nearest tag (plus a second within `tag_second_within`); the agent names each from its central titles, and labels that clash are asked again together. A dry run reports the cut, sizes, central titles and -- where tags exist -- the adjusted Rand agreement with them and each built tag's largest current tag: the check before `cluster_tags.py` is retired (Ben). The range's top is `tag_build_max` in platform.lua (default 60) or `--max-tags N`; and `tag_build_coarseness` (`--coarseness C`, default 0) leans the cut to fewer tags while leaving it to the data: a level scores its life / tags^C, so a level with more tags must live clearly longer to win, and the dry run lists the five best levels (2026-10-29: Ben found 50 too many). Writing is refused while computed tags exist, unless `--replace` (2026-10-29): the computed tags and their memberships are archived once the new ones are planned and named, just before they're written; refused while a computed tag holds a membership a person set. Checked against the outside job's tags (2026-10-13), which it then replaced (2026-10-14).
4. **Done: core evidence.** `link` (directed) and `connection` (a connection document is one undirected edge, never two links) rows in `tag_evidence`, producer `core`; an edge's unit is shared evenly across its documents' tags. Recomputed when read and its inputs' fingerprint changed (link and membership counts, latest ids), not on every write, since one outside job's apply writes thousands of memberships; `daat repair tag-evidence` forces it. `tag.evidence` returns each row's lift within its own kind (minimum support 3, shrunk towards 1 by two median weights). Parity with the deployment's batch analysis is checked once deployed.
5. **Done: `#tag` in text.** Parsed and synced on save next to `document.sync_links` (`tag.sync_text_tags`), `document_tag.via = text`, rendered as chips linking to the tag. Two rules the doc's syntax didn't have, from measuring imported content (6,865 documents would have made 172 tags out of spreadsheet errors and catalogue numbers): only a person's write counts (not `system`, not an API key's import or sync), and an edit asserts only the `#tags` it added; and `#REF!`/`#NAME?` (a tag followed by `!` or `?`) aren't tags.
6. **References.** *Done:* `src/reference.lua` -- `entity_name_index` (the lookup index, kept by every entity type's hooks) and `document_mention` (synced on save next to `document.sync_links`); only distinctive, unambiguous names; spacing- and separator-insensitive; `reference_aliases` in platform.lua; `daat repair references`. Evidence: `reference:<entity type>` and `shared_link` (two documents linking the same page), one unit per target, two documents a side. *Next:* entity-to-entity lineage from reference fields, between the referenced entities' documents' tags.
7. **The agent's judgment:** names, definitions (genus = broader tag, difference from siblings, relations from evidence), related/broader on pairs whose evidence crosses the thresholds, merge/split raised in chat; memoized on member and evidence hashes. Thresholds set from labelled pairs first.
8. **UI:** chips on documents, the tag page, the tags list; agent tools.
9. **Optional:** SKOS/RDF export (`skos:Concept`, `broader`, `related`, `definition`) so an outside checker such as [open-ontologies](https://github.com/fabio-rovai/open-ontologies) can validate it.

## Open questions

- One tag per document or several. The data (40% of documents within 0.05 of a second tag) argues for a main tag plus a close second.
- The level-cut thresholds, set from the first runs.
