# Tier curation ladder

Proposal, 2026-10-28. Replaces tiers as labels on raw content with tiers as stages of curation work the agent does, one step at a time.

## Problem

In production (2026-10-28, 7,478 active documents), every document above tier 1 is unprocessed:

| Tier | Documents | What they are |
|---|---|---|
| 3 Atomic Record | 3 | a 151k-character chat transcript with raw tool results (#292404), a one-sentence connection note, a synced PDF |
| 2 Developed Reference | 6 | synced files up to 200k characters |
| 1 Curated Draft | 133 | synced files, average 71k characters |
| 0 Raw Intake | 7,336 | everything else, including all 132 distilled facts |

The documents the agent did curate (distilled facts) sit at tier 0, and raw sources sit above them. Search weights by tier (`document.TIER_WEIGHT`), so raw sources are boosted over the curated notes.

Causes (`knowledge.review_retrieval`, `knowledge.judge_promotion_target`):

1. **The gate to leave tier 0 is any edit** (`document.was_revised`: one `update` event). A chat transcript gets one on its second turn, and a synced file on its second sync.
2. **The judge sees only the body.** No title, no source type, nothing saying "this is a chat transcript". One call can move a document from 0 to 3.
3. **Promotion never changes content.** A tier is a label put on the text as it is, so a raw source can only ever be labelled, never improved.
4. **Distillation is one fact per source, ever.** The fact starts at tier 0 and is judged only once it's retrieved twice. The source isn't linked to it, and similar facts aren't deduplicated.

## The ladder

A tier is earned by curation work, not assigned to raw text. Each step up is the agent writing a cleaner document from the step below, and a judge checking that work before it counts.

| Tier | What it is | Made by | From |
|---|---|---|---|
| 0 Raw | every source as it arrived: synced files, chat transcripts, reasoning, experiment views, connection notes | sync, chat, review | — |
| 1 Curated note | one source rewritten as a clean note in the agent's words: what it is, key findings, numbers, with a link to the source. A chat becomes its conclusions, not its transcript. | **curate** step | one tier-0 source |
| 2 Developed reference | a structured reference on one subject, synthesized from several tier-1 notes, with sections and links to each note | **synthesize** step | ≥ 3 tier-1 notes on one subject |
| 3 Atomic record | one verified idea, short and self-contained, deduplicated against existing records | **distill** step | a tier-2 reference (or a tier-1 note) |

Rules:

- **Raw stays raw.** A source never moves above tier 0. Only documents the curation wrote can hold tiers 1-3. This includes synced files, transcripts, reasoning and connection notes.
- **One step at a time.** A document is made from the tier directly below it. Nothing jumps from raw to atomic.
- **The agent rewrites only its own documents.** Sources are never edited; the pool stays additive for everything it didn't write. A tier-2 reference is updated in place when new tier-1 notes on its subject arrive, so it grows instead of being duplicated. Pages people write stay as they are (see the open questions).
- **Every step is checked.** A judge call compares the new document with what it was made from: is it faithful, does it add nothing that isn't there, is it cleaner? A failed check discards the draft and records why. The current judge prompt's lessons (a reminder isn't a record, a list of links isn't a definition, fidelity to the source) move into these checks.
- **Driven by use, run in the background.** A step is queued when a document is used (the `due_for_review` rule today: retrieved twice, or hot), not by a scan of the whole pool. It runs in the jobs worker (`platform-jobs`, every 2 min), not inside the search request. That also removes the review time from search latency (brex 712351373).
- **Provenance is kept.** Each curated document records what it was made from (`source_id`, plus `document_link`s so the graph and the "cite sources" check see it), and the agent's prompt and output are logged in `agent_model_call` as today.

Search keeps its tier weights, so curated documents now rank above the raw sources they came from, and a reader can follow the links down to the source.

## Subjects for tier 2

A tier-2 reference needs a subject that several tier-1 notes share. Tags already give one: each tier-1 note is placed in a tag when it's embedded, so a tag with ≥ 3 tier-1 notes and no reference is a candidate. The reference lives under its tag and is updated when the tag gains notes. Tag splits and merges (tag upkeep) re-point references the same way they move memberships.

## Reset

Every document above tier 0 today is raw, so the ladder starts from a reset:

1. All documents to tier 0, and `document_tier_judgment` cleared.
2. The 132 existing distilled facts are kept but marked legacy. They're one fact per source, unchecked and partly duplicated. The new distill step can absorb them: it deduplicates against them and archives a legacy fact once a checked record covers it.
3. Curation then starts from use. The first searches queue curate steps for the sources they touch.

The reset is a migration (`store` migration 7). It's reversible from the Cloud SQL backup, and it changes no content, only tiers.

## Cost

Each step is one generation call plus one check call. With the use gate, the first weeks would be roughly the documents searched twice: 133 are at tier 1 today by that rule, so about 260 calls to curate them, then a trickle. Chat transcripts are the largest inputs (up to 300k characters). The curate step reads a transcript's conversation without the tool results (`transcript_conversation`, already used for embeddings) and caps the input size, as the judge already does with `TIER_JUDGMENT_SOURCE_MAX_CHARS`.

## Phases

1. **Stop the damage:** raw stays raw (sources capped at tier 0), give the judge the title and the source type, then the reset. Small change; it makes tiers honest right away.
2. **Curate (tier 1):** the curate step and its check, queued from review and run by the jobs worker. Move review out of the search request at the same time.
3. **Synthesize (tier 2):** references per tag, updated in place.
4. **Distill (tier 3):** records from references, deduplicated by embedding against existing records; legacy facts absorbed.

Status:
- **Phase 1** is done (2026-10-28): `knowledge.can_hold_tier`, the judge sees title and kind, and store migration 7 reset every tier.
- **Phase 2's curate step** is built (`src/curate.lua`):
  - Review queues a source once it's due (`knowledge_curation`, one row per source and content version).
  - The jobs worker runs `daat knowledge curate-pending 3` every 2 minutes (software `startup-platform.sh.tpl`).
  - `daat repair curate [--limit N] [--dry-run] [--recheck]` backfills the sources already in use, most used first. `--recheck` tries again the sources that came to nothing, were rejected or failed (after a prompt change).
  - The agent first judges whether the source is in the team's field (published papers, books and reviews on its subjects count) and answers `NOTHING: <reason>` when it isn't.
  - A source longer than 40,000 characters is cut, with a line saying so; the check sees the same cut text.
  - A runner claims a queued source (pending -> running, with its own token) before curating it, so a `repair curate` batch and the jobs worker never curate the same source twice. A row left running by a process that died is retried by `--recheck`.
  - A note that passes the check is created at tier 1 with a `Source: [[...]]` link. A source edited later gets its note rewritten in place.
  - Moving the rest of review out of the search request is still to do.
  - Review no longer judges the tier of a document the curation wrote: it keeps the tier its step gave it. Found 2026-10-29 before it happened in production: the old judge path would have reset a fresh tier-1 note to 0 on its second retrieval (never "revised"), or moved a revised one to any tier.
- **Phase 3's synthesize step** is built (`src/synthesize.lua`, 2026-10-29), on the tags rebuilt that day (`daat tag build --name --replace`: 50 tags).
  - A tag is due once it holds 3 or more curated notes and has no reference, or its notes changed since (`knowledge_reference`, one row per tag, with the notes' hash).
  - The agent writes one structured reference from up to 12 of the tag's notes, most central first: sections by theme, duplicates merged, disagreements stated, every statement cited `[[Note title]]`. A few notes off the tag's subject are left out and named in a closing `Left out:` line; it answers `NOTHING: <reason>` only when most notes share no subject, or the subject is outside the team's field (2026-10-29: one coffee note had sunk a tag of nine cocoa fermentation notes). It reads each note without its `Source:` line, so the reference cites notes, not the raw sources behind them.
  - A second call checks every statement against the note it cites, and that no note's main point was dropped silently.
  - A reference that passes is created at tier 2 (`source_type = 'reference'`, `source_ref = 'tag:<id>'`) and links every note it was made from; it is rewritten in place when the tag's notes change.
  - `daat repair synthesize [--limit N] [--dry-run] [--recheck]` runs it; a runner claims a tag before writing, as curate does.
  - A reference whose tag was archived is archived on the next run (repair or the worker), and its row dropped: a tag rebuild archives every computed tag, and on 2026-10-30 left 15 references on archived tags beside the new tags' references to come. The jobs worker runs `daat knowledge synthesize-due 1` every 2 minutes: one tag whose notes changed, or that newly holds enough notes.

- **Phase 4's distill step** is built (`src/distill.lua`, 2026-10-29) as designed below, with the three decisions as proposed: records from references only; a legacy fact a record covers is archived into it; 0.80 cosine with the agent judging every pair above it.
  - `daat repair distill [--limit N] [--dry-run] [--recheck]`, and `daat knowledge distill-due [N]` for the jobs worker; `knowledge_distillation` keeps one row per reference.
  - Reactive distillation (`knowledge.maybe_distill`, one legacy fact per raw source, written inside the search request) no longer runs.
  - Not yet: re-checking a rewritten reference's existing records against its new text (a rewrite distills again and dedup keeps records from repeating, but a record the new text no longer supports stays).

## Tier 3 design (2026-10-29)

Where it starts: 16 tier-2 references in production, 147 tier-1 notes, and 132 legacy distilled facts (`source_type = 'distilled'`, about 300 characters each, 3 ever retrieved, some near-duplicates: #210426 and #204996 both say C.COT.M-1D is best for ICS 39 callus).

**What a record is.** One claim a reader can use on its own: a finding with its numbers and conditions, a protocol parameter, a definition. Self-contained (it names the organism, line, medium or method it's about), 1-3 sentences, titled with the claim itself, not a topic. It cites the tier-1 note(s) it comes from and links to the reference it was distilled from.

**The step (`src/distill.lua`, replacing the legacy distill path):**

1. **Trigger.** A tier-2 reference that is new or was rewritten (`knowledge_distillation`, one row per reference with its content hash, like `knowledge_curation`). Run by `daat repair distill` and the jobs worker, after synthesize.
2. **Extract.** One call reads the reference plus the notes it cites and lists up to 12 claims, the ones a team member would look up: results with numbers, conditions that worked or failed, definitions. Each with the note(s) it rests on.
3. **Dedup by embedding.** Each candidate is embedded and compared with active records and legacy facts (cosine, the same vectors search uses):
   - below 0.80: new;
   - 0.80 and up: one judge call over the candidate and its nearest matches answers SAME (keep the existing record, add the new note as a source), UPDATE (the candidate is more complete or more exact: rewrite the existing record in place), or NEW.
   A legacy fact matched SAME or UPDATE is archived with `merged_into` the record, so the legacy set shrinks as tier 3 grows.
4. **Check.** One call checks every new or rewritten record against the note(s) it cites, as curate and synthesize do. A record that fails is dropped with its reason recorded; the others are kept.
5. **Write.** `source_type = 'record'`, tier 3, `source_ref = 'reference:<id>'`, links to its notes and reference.

**When a reference is rewritten,** its records are re-checked against the new text: still supported stays, no longer supported is archived, new claims go through dedup. Records are never duplicated across references: dedup sees all of them.

**Cost.** Per reference: one extract, one check, one embedding per claim, and a judge call only for near matches. About 16 x 2-4 calls for the backfill.

**Search.** Records are short and weighted highest (`TIER_WEIGHT` 0.35), so a precise question should hit a record first and follow its links down to the note and the source.

**Decisions needed:**
1. Records only from references, or also from tier-1 notes in tags without one (147 notes, 16 references today)? Proposed: references only at first; notes later if records stay thin.
2. Legacy facts: archive them as records cover them (proposed), or leave them all as they are?
3. Dedup threshold: start at 0.80 cosine with the agent judging every pair above it (proposed), measured on prod before trusting it.

Each phase comes with scorecard scenarios (a chat transcript never rises; a curated note cites its source; a reference covers its notes) and a check on production: `daat knowledge stats` by tier and type, before and after.

## Decisions (2026-10-28)

1. **Pages people write** stay out of the ladder, at tier 0. They're sources the agent curates from, never relabelled.
2. **Chats** get a curated note only when they have conclusions worth keeping. The curate step can answer "nothing to keep".
3. **Legacy distilled facts** (`source_type = 'distilled'`) are kept and absorbed gradually. The new steps use new source types (`curated`, `reference`, `record`), so the legacy facts stay identifiable without marking them.
4. **Curated documents** live in the Knowledge Pool folder, as today. Tags group them by subject.
