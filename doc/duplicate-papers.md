# Duplicate papers

The same file copied into several SharePoint folders arrives as several documents: one per SharePoint item, each with its own folder header and sometimes its own text extraction. Every copy is then searched, judged, distilled and linked on its own. The same facts get distilled twice, and links to one paper are split across its copies.

Production, 2026-10-28 (5,729 synced files): 391 groups with identical text (628 extra copies: 350 PDF, 163 Word, 99 spreadsheet, 16 slides), and 31 more pairs of PDFs with the same title whose text extraction differs.

## What counts as a copy

`daat repair duplicates` (src/duplicate.lua) pairs copies two ways, with no model call:

- **Same text.** The same body once the sync header (`document.preamble_end`) is cut off and whitespace collapsed. This applies to any file type: identical text loses nothing but a second location.
- **Same paper.** Two PDFs whose titles match once case, punctuation and a leading year are dropped ("2014 Genome-wide…" and "Genome-wide…"), with at least 80% of the smaller one's word 5-grams found in the other and word counts within 80% of each other.

Only PDFs are matched by title. Two spreadsheets or protocols with the same title and most of the text in common are usually two versions whose differences matter (for example "EXPERIMENT 42 DATA" x3, 89% shared).

Only synced files are considered (`external_id` `sharepoint:…`). A page someone wrote is never folded into another, which is the rule `knowledge.duplication_status` keeps too. Bodies shorter than 2,000 characters are stubs (folder pages, files whose text didn't extract) and are skipped.

## Folding

The copy with the lowest id whose title says what the file is gets kept. A bare number or date, a few characters, or a copy's name ("- Copy", "(2)") doesn't count: in production "17.pdf" would otherwise have been kept over its copy titled "Rojas et al 2015" (44 of 405 groups). If no title qualifies, the lowest id is kept. `[[Title]]` links still resolve, since resolution only looks at active documents. For each other copy:

1. Links to the copy point at the kept document. A link from the kept document to its own copy is archived.
2. `duplicate_of` and `merged_into` record where it went.
3. It's archived (reason "duplicate of #N"), like any document leaving the pool. Its heat goes back to the pool, its vector leaves its tags' centres, and its embedding and outgoing links go (`document.on_entity_archived`).

A connection document (A ↔ B) left linking a paper to itself is archived too.

A later sync updates the archived copy in place and doesn't bring it back: `entity.update` leaves `archived_at` and `merged_into` alone, and the embedding queue skips archived rows.

## Running it

```
daat repair duplicates --dry-run   # list what would be folded, write nothing
daat repair duplicates             # fold
```

It's idempotent: folded copies are no longer candidates, so a rerun only finds copies synced since.

## Not covered yet

- Word and PDF versions of the same document (124 same-title pairs in production share at least 80% of their text). These are probably the same text in two formats, but they need a sample check before they're folded.
- Facts already distilled from two copies stay as they are. Duplicate facts are their own task.
- New copies are folded only when the repair runs. Running it from the jobs timer, or at review time, is the next step.
