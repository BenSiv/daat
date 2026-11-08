# Historical chats: migration to the agent-data format

Plan, 2026-11-08. Expands the Migration section of `doc/agent-data.md` (issue #23) into steps that can be run, checked and undone. It covers what already exists on celleste-lims: the sessions, their messages, their `chat_session` transcript documents and their stored prompts. Nothing here runs before the code it depends on.

## What changes for an old chat

| Today | After |
|---|---|
| `agent_message` rows typed only by `role` | each row has `data_type` and `loop = chat` |
| A shared `chat_session` document in the pool, tool results included | a curated note in the pool; the transcript document is archived |
| Curated only after two retrievals (4 of 49 are) | every conversation curated once, or marked `NOTHING` |
| Stored prompts kept 90 days | kept 30 days (`model_input_days`) |
| Tool results kept forever | stubbed after 90 days (`tool_trace_days`) |

The conversation itself stays readable on `/chat` for its owner, and no message row is deleted.

## Production, 2026-11-08

Read-only, aggregates only (`platform_readonly`).

**Sessions:** 61 sessions from 7 logins, 2026-09-03 to today. 49 have a transcript document (29 admin, 20 staff). The other 12 never got one: 9 admin and 3 staff, all from 2026-09-16 to 2026-10-14, each 1 to 4 turns and under 2.6k characters.

**Messages, and the type each one gets:**

| `role` | Rows | Characters | `data_type` |
|---|---|---|---|
| `user` | 217 | 41k | `request` |
| `assistant` | 1,315 (166 text blocks, 1,165 tool-call blocks) | 677k (text 211k) | `answer`; tool-call blocks are read as trace |
| `tool_result` | 1,112 | 2.77 M | `tool_trace` |
| `compaction_summary` | 108 | 130k | `reasoning` |
| `self_check` | 7 | 6k | `reasoning` |
| `error` | 6 | 1k | `control` |
| `progress` | 1 | 0.4k | `answer` |

Every assistant row is valid JSON with `blocks`, so the split by block type needs no special cases.

**Transcript documents:** 49 active, 2.77 M characters, 13 retrievals. Without tool output, a conversation averages 5.0k characters (max 22.8k, 3 under 500). None reaches the 40k curation input cap, so each needs one curate call and nothing is cut. Other rows point at them: 80 active links, 57 active tags, aspects on 12 documents, and 28 retrieval hits (10 in a top 5).

**Curation:** 4 transcripts curated (each has a `curated` note), 45 never queued.

**Prompts:** 1,459 stored, 1,241 older than 30 days (18.7 M characters).

## Steps

Each step needs one implementation piece of `doc/agent-data.md` to be deployed first. Each one has a dry run that prints what it would do, and each writes a run log to `~/database/analysis/datasets/chat-history-migration/`, never into the repo.

### 1. Type the rows (with piece 1, typed storage)

- The schema upgrade that adds `data_type`, `loop` and `parent_message_id` also backfills them: `UPDATE agent_message SET data_type = ... WHERE data_type IS NULL`, by role, as in the table above, with `loop = 'chat'`. Rows already typed are left alone, so the upgrade can run more than once.
- `agent_model_call.loop` is backfilled from `kind` where it is set (`chat`, `research`, `background`, `self_check`, `compaction`, `wrapup` -> `chat`) and is `chat` where `kind` is NULL.
- Earlier research steps aren't recoverable, as `doc/agent-data.md` says. Their prompts expire in step 4.
- **Check:** `SELECT COUNT(*) FROM agent_message WHERE data_type IS NULL` is 0, and the role-by-type counts match the table above.
- **Undo:** the columns are new. Dropping them, or leaving them unread, restores today's behaviour.

### 2. Curate every old conversation (with piece 2, curation by type)

Piece 2 makes the conversation the curation source (its `request`, `answer` and `reasoning` rows) and queues it after `agent_curate_quiet_minutes`. Every historical session is quiet and never curated with the new reader, so the new queue would pick up all of them on its first pass. The migration makes that pass explicit and paced:

- `daat repair curate-chats [--dry-run] [--limit N] [--skip-login LOGIN]` lists every session that is due (by the piece-2 rule), with its owner, turns and input size, and then curates them in order, oldest first.
- Scope: the 49 sessions with transcripts plus the 12 without, since piece 2 curates conversations and not documents (decision 2).
- The 4 already curated are redone with the new reader, and each note is rewritten in place (`write_note` with its `note_id`), so links to it hold (decision 3).
- Admin sessions follow decision 1.
- Cost: about 61 curate calls plus their checks, at about 5k characters of input each. Run it outside the nightly sync window (02:00 UTC, 2 to 3.5 h).
- **Check:** every session has a curation row whose status is `curated` or `nothing`. Failed and rejected sessions are listed, and their transcripts stay active (step 3).
- **Undo:** the curated notes are ordinary pool documents and can be archived. No source is changed.

### 3. Retire the transcript documents (with piece 2, `agent_transcript_documents = off` deployed)

- Order matters: transcripts are retired only once new turns have stopped writing them. Otherwise `sync_session_document` keeps updating an archived document whenever an old chat is resumed, and each new chat still gets a document.
- `daat repair retire-transcripts [--dry-run]` archives each `chat_session` document whose session has a `curated` or `nothing` curation. It skips the rest and says why for each.
- Archiving sets `archived_at` only. Links, tags, aspects and retrieval hits stay as rows, and search already leaves archived documents out. Hits stay because link decisions read old co-retrievals (`doc/schema-revision.md`).
- The curated note's source line points at the transcript document today. After retirement it should point at the conversation on `/chat`, which only the owner and admins can open (decision 5).
- **Check:** no active `chat_session` documents. A search for a few questions old chats answered (picked from the dry-run list) returns the curated notes.
- **Undo:** `daat repair retire-transcripts --undo <run log>` clears `archived_at` on the documents that run archived.

### 4. Apply retention (with piece 3, retention strategies)

- Production runs `standard`. On the first `daat store prune`, 1,241 of the 1,459 stored prompts lose their text (18.7 M characters). Token counts, evaluation and feedback stay.
- Tool results are stubbed after 90 days. The oldest message is from 2026-09-03, so the first stubs appear on 2026-12-02, not on the first prune.
- Raw knowledge (`request`, `answer`, `reasoning`) is kept forever under `standard`.
- **Undo:** none in the app. Cloud SQL keeps 14 daily backups, so cleared prompts can be recovered from a backup for about two weeks, and after that they are gone. Take an on-demand backup right before the first prune.

## Order

1. Piece 1 deployed, backfill checked (step 1).
2. Piece 2 deployed with the transcript documents still on. Run `curate-chats --dry-run`, review the list, then run it (step 2).
3. Switch `agent_transcript_documents` off and run `retire-transcripts --dry-run`, then run it (step 3).
4. Piece 3 deployed: take a backup, then run the first prune (step 4).

Steps 2 and 3 can run on daat-test first, though under `lean` there step 3 is followed by removing the raw knowledge after 30 days.

## Decisions for Ben

1. **Admin sessions** (29 of the 49 transcripts, 9 of the 12 without one) are mostly testing. Curate them like the rest and let curation answer `NOTHING` where it should, or skip them (`--skip-login admin`), mark them `nothing` without a model call, and retire their transcripts? Recommended: skip. Test chats written up as team notes would add noise to the pool.
2. **The 12 sessions without a transcript:** curate them too? Recommended: yes for the 3 staff sessions. The admin ones follow decision 1.
3. **The 4 already-curated transcripts:** redo them with the new reader, which also reads reasoning, and rewrite each note in place? Recommended: yes.
4. **Past approvals:** write them now as `request` rows from `agent_pending_action`? Recommended: no. Conversations are ordered by id, so rows added now would land after the turns they belong to. Curation can read decided actions beside the conversation for these sessions instead.
5. **A note's source after retirement:** point it at the `/chat` conversation (owner and admins only), or name the source without a link? Recommended: the `/chat` link. Other readers see a source they can't open, which is the visibility the design chose.

## TODO

- [ ] Ben: decisions 1-5.
- [ ] Piece 1: the backfill in the schema upgrade, with a test that a store with old rows comes out typed.
- [ ] Piece 2: `daat repair curate-chats` and `daat repair retire-transcripts` (with `--undo`). Tests: the dry run changes nothing; a failed curation keeps its transcript active; `--undo` restores what one run archived.
- [ ] Piece 3: a test that the first prune keeps every token row.
- [ ] Run on daat-test, then on production, in the order above. Record before and after numbers here.
