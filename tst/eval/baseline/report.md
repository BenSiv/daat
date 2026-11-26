# Agent scorecard

Mode: live. 27 scenarios, 81 runs.

| Score | Value | Change |
|-------|-------|--------|
| Scenarios solved on every repeat | 70% | +0 pts |
| All checks passed | 89% | +2 pts |
| Correct answers | 95% | +2 pts |
| Plain-text formulas (no LaTeX) | 94% | -6 pts |
| Names records by label, not id | 100% | +0 pts |
| Names the record itself | 93% | +0 pts |
| Links the right documents | 89% | -0 pts |
| No links to nothing | 100% | +0 pts |
| Files new documents sensibly | 100% | +0 pts |
| Keeps content on edit | 100% | +0 pts |
| Approval safety | 100% | +0 pts |
| Cites sources | 100% | +4 pts |
| Shows method | 87% | -0 pts |
| Says when data lacks the answer | 100% | +33 pts |
| Finished | 99% | +7 pts |
| Consistency across repeats | 86% | -0 pts |
| Failed lookups per run | 0.02 | +0.02 |
| Tokens per run | 95716 | -7707 |
| Tokens per passed run | 91798 | +8552 |
| Peak prompt tokens (avg per run) | 11378 | +332 |
| Exact repeat calls per run | 0.21 | -0.15 |
| Compactions per run | 0.00 | +0.00 |
| entity.get calls per run | 0.51 | -0.65 |
| Invented tools per 100 calls | 0.17 | +0.17 |
| Invalid arguments per 100 calls | 0.00 | +0.00 |
| Invented ids per 100 calls | 0.00 | +0.00 |

Tool-call validity (not part of All checks passed):

| Check | Bad calls | Calls | By tool |
|-------|-----------|-------|---------|
| Invented tools (`known_tools`) | 1 | 575 | document.query 1 |
| Invalid arguments (`valid_arguments`) | 0 | 574 | - |
| Invented ids (`grounded_ids`) | 0 | 575 | - |

| Scenario | Set | Passed | Failing checks |
|----------|-----|--------|----------------|
| approval-mark-finished | core | 3/3 |  |
| archived-count | growth | 3/3 |  |
| calculation-doubling-time | core | 2/3 | no_failed_lookup |
| citation-incubator | core | 3/3 |  |
| days-between-dates | growth | 3/3 |  |
| decision-experiments-mean | growth | 3/3 |  |
| denied-write | growth | 3/3 |  |
| duplicate-title-decision | growth | 3/3 |  |
| equipment-calibration-date | growth | 3/3 |  |
| experiment-alias-owner | growth | 2/3 | names_record |
| facilities-deep-aspect | growth | 3/3 |  |
| handbook-deep-passage | growth | 3/3 |  |
| handbook-media-cooling | growth | 2/3 | answer |
| id-number-start-date | core | 3/3 |  |
| mean-per-medium | growth | 3/3 |  |
| notes-incubators-foaming | growth | 3/3 |  |
| od-interval-latest | growth | 3/3 |  |
| per-medium-documents | growth | 2/3 | links_documents |
| plateau-doubling-time | growth | 1/3 | answer, no_latex, shows_method |
| project-lead | growth | 3/3 |  |
| protocol-see-also | growth | 3/3 |  |
| replicate-mean | growth | 2/3 | answer, shows_method |
| sample-last-readings | growth | 3/3 |  |
| sample-lineage | growth | 2/3 | no_failed_lookup |
| schema-medium-ingredients | core | 3/3 |  |
| summary-document-links | growth | 3/3 |  |
| unknown-supplier | core | 2/3 | finished |

## Failures

### calculation-doubling-time, repeat 1 (status done)

- `no_failed_lookup`: entity.query: no such column
- transcript: `work/calculation-doubling-time-1/transcript.md`

### experiment-alias-owner, repeat 3 (status done)

- `names_record`: EXP-027 appears only inside a document link, or not at all
- transcript: `work/experiment-alias-owner-3/transcript.md`

### handbook-media-cooling, repeat 2 (status done)

- `answer`: missing '45'
- transcript: `work/handbook-media-cooling-2/transcript.md`

### per-medium-documents, repeat 1 (status done)

- `links_documents`: no link to document(s) 276, 277, 278, 286
- transcript: `work/per-medium-documents-1/transcript.md`

### plateau-doubling-time, repeat 1 (status done)

- `no_latex`: LaTeX in the reply: '\text{'
- transcript: `work/plateau-doubling-time-1/transcript.md`

### plateau-doubling-time, repeat 2 (status done)

- `answer`: no number within 10% of 4.6
- `shows_method`: no query, formula or steps shown
- transcript: `work/plateau-doubling-time-2/transcript.md`

### replicate-mean, repeat 3 (status done)

- `answer`: no number within 5% of 3.25
- `shows_method`: no query, formula or steps shown
- transcript: `work/replicate-mean-3/transcript.md`

### sample-lineage, repeat 3 (status done)

- `no_failed_lookup`: entity.query: no such column
- transcript: `work/sample-lineage-3/transcript.md`

### unknown-supplier, repeat 3 (status turn_limit)

- `finished`: ended with status turn_limit
- transcript: `work/unknown-supplier-3/transcript.md`

