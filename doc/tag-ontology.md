# Tag ontology: subjects the data defines and the agent describes

Status: proposal, 2026-10-02 (Ben). Not agreed yet. Builds on [structure-layers.md](structure-layers.md)'s tags; only `tag.parent` exists so far (daat e7f8eb8).

Today a tag is a flat cluster label with a fixed count (`k`) chosen by hand and a one-off name. The goal is a subject ontology that comes from the data and is described by the agent, the same way progressive summarisation and connections already work: the data decides how many subjects there are and how they nest; the agent names them, describes them and judges how they relate; people review and override through the same UI as everything else.

## What the ontology is

| Part | Stored as | Decided by |
|---|---|---|
| Subjects | `tag` rows | the data (clustering), at every level |
| Membership | `document_tag` rows, as now | the data; `pinned`/`excluded` by people |
| Broader / narrower | `tag.parent` | the data (the cluster tree); a person's move wins |
| Related (across branches) | `[[links]]` in subject notes | the agent, on candidates the data proposes |
| Same subject twice | a merge proposal | the agent proposes, a person approves |
| Name and scope | `tag.label`, the subject note | the agent; a person's rename wins |

The relation vocabulary is SKOS's (broader, narrower, related, exact match) and nothing more. Membership stays derived and is never written into documents' text ([structure-layers.md](structure-layers.md), Tags), but what a subject *is* and how it relates to other subjects is knowledge, so it lives in content: each subject gets a **subject note**, an ordinary document filed under a "Subjects" folder, written by the agent: what the subject covers, what it doesn't, and `[[links]]` to its broader, narrower and related subjects. `tag.note` points at it. Because it's a document, it's searchable, shows in the graph, has history, enters tiering and heat, and a person edits it like any other page. That's the same choice connections made: a connection is an ordinary connection document, not a hidden edge.

## The data decides the shape

No fixed `k`, no fixed depth.

1. **Micro-clusters.** k-means into many small groups (about √n, ~80 at 6,600 documents) on the existing cleaned, passage-sampled document embeddings. Cheap, and fine-grained enough that nothing real is merged yet.
2. **Tree.** Agglomerative clustering (Ward) over the micro-cluster centres, weighted by size, gives one tree of all subjects.
3. **Levels.** Cut the tree where merge distances jump: a large gap means "these groups are genuinely separate". The largest gap above the leaves gives the specific level; the next one up gives the broad level, if there's a clear one. A level only exists if the gap is clearly larger than the gaps below it, so depth is 1-3 depending on the corpus, not set by hand.
4. **Guard rails, not targets.** A broad level with more than 12 groups (the graph's palette) or a subject with fewer than ~10 documents is reported as a warning in the plan, not forced.
5. **Stability.** Each level keeps names by member overlap with the previous run (as now); a subject with no match is new; one that disappears is archived unless a person pinned documents to it or renamed it.

The same numbers say *when* to recompute, as a rule rather than a schedule: after each sync, new and changed documents are assigned to their nearest specific subject (cheap, no reclustering). A full recompute is due when enough of the pool is new since the last one (e.g. 15%), or when many new documents sit far from every subject centre (the pool has grown a subject the ontology doesn't have). A person can also request one.

## The agent describes and relates

Model calls only for judgment, each memoized on a hash of the subject's members so an unchanged subject is never re-asked, as `knowledge_tier_review` does for tiers:

- **Name** each subject from its most central titles, its terms and, for a broad subject, its children's names.
- **Write the subject note**: scope, what's in and out, and its broader/narrower links (which the tree already decided).
- **Judge related pairs.** Candidates come from the data: subjects in different branches whose centres are close, that share many second-best memberships, or whose documents link to each other a lot. The agent answers yes or no per pair, with a reason grounded in both subjects' central documents, like the co-retrieval link judgment. A yes becomes a `[[link]]` in both notes.
- **Propose merges and splits.** Two subjects the agent judges to be the same, or one that covers two unrelated things, become proposals, not changes.

Additive work (names for new subjects, notes, related links) happens automatically, as distillation does. Structural changes a person might disagree with (merge, split, moving a subject) wait for approval, as the agent's destructive tools do.

## Where it runs

The [boundary](structure-layers.md#boundary) stays: numbers outside daat, judgment and display inside.

| The clustering job (`software`) | daat |
|---|---|
| Embeddings, micro-clusters, the tree and its cuts | Stores subjects, membership, `tag.parent` |
| Stable matching, recompute-due rule, incremental assignment | Runs the judgment calls with its own agent provider, triggered when a subject is new or its member hash changes |
| Related-pair candidates (written as a `tag` candidate list) | Subject notes, related links, merge/split proposals |
| Writes through the REST API, ledgered | UI and manual overrides |

Moving naming from the job into daat means every judgment uses daat's provider, budgets and audit trail, and a person sees all of it in one place.

## The UI

Like everything else: no special screens beyond one page.

- **Subjects page** (core, next to `/knowledge`): the tree, broad to specific, with document counts, each subject linking to its note and its members. Controls: rename, move under another subject, pin or exclude a document, approve or reject the agent's proposals, request a recompute.
- **Subject notes** are ordinary documents: read, edit, history, graph.
- **Graph**: colour by broad subject or specific subject (built), filter by subject through the legend.
- **Document page**: its subjects, as breadcrumbs (broad › specific).
- **Chat agent tools**: `subject.tree`, `subject.get` (note, members, relations) and `subject.propose`, so the agent can answer "what do we know about X" by subject and propose changes that go through the same approval as other writes.

A person's change always wins over a recompute, at every level: a renamed or moved subject keeps its name and place, pinned and excluded memberships stay, and an edited subject note isn't overwritten (the agent appends a suggested revision instead).

## Phases

1. **Done:** `tag.parent`; graph colours by broad or specific subject (daat e7f8eb8).
2. **Data-driven tree** in the clustering job: micro-clusters, tree, gap-based levels, stable matching per level, the plan report as a tree. Validate on the current pool before applying: does it find sensible broad groups, and are the old literature subjects still there?
3. **Judgment in daat**: subject notes, names, related-pair judgments and merge/split proposals, memoized on member hashes; `tag.note`.
4. **UI**: the subjects page with overrides and proposals; subjects on document pages; agent tools.
5. **Triggers**: incremental assignment after each sync; the recompute-due rule; the request button.

## Open questions

- One subject per document or several. The current data (40% of documents within 0.05 of a second subject) still argues for a primary plus a close second.
- Whether people should be able to create subjects by hand that the data doesn't have (a `manual` tag with a note); storage already allows it.
- The gap rule's thresholds, set from the first runs rather than up front.
