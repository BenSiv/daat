# Agent scorecard

Mode: live. 27 scenarios, 81 runs.

| Score | Value | Change |
|-------|-------|--------|
| Scenarios solved on every repeat | 70% | -4 pts |
| All checks passed | 85% | +0 pts |
| Correct answers | 94% | -3 pts |
| Plain-text formulas (no LaTeX) | 100% | +0 pts |
| Names records by label, not id | 100% | +0 pts |
| Names the record itself | 93% | +13 pts |
| Links the right documents | 89% | +11 pts |
| No links to nothing | 100% | +0 pts |
| Files new documents sensibly | 100% | +0 pts |
| Keeps content on edit | 100% | +0 pts |
| Approval safety | 93% | -7 pts |
| Cites sources | 96% | -4 pts |
| Shows method | 80% | -20 pts |
| Says when data lacks the answer | 67% | +33 pts |
| Finished | 91% | -2 pts |
| Consistency across repeats | 86% | -5 pts |
| Failed lookups per run | 0.00 | -0.02 |
| Tokens per run | 103423 | -3679 |
| Tokens per passed run | 83562 | -3831 |
| Peak prompt tokens (avg per run) | 11046 | -443 |
| Exact repeat calls per run | 0.36 | +0.16 |
| Compactions per run | 0.00 | +0.00 |
| entity.get calls per run | 1.16 | +0.41 |

| Scenario | Set | Passed | Failing checks |
|----------|-----|--------|----------------|
| approval-mark-finished | core | 2/3 | approval, finished, state |
| archived-count | growth | 3/3 |  |
| calculation-doubling-time | core | 3/3 |  |
| citation-incubator | core | 3/3 |  |
| days-between-dates | growth | 3/3 |  |
| decision-experiments-mean | growth | 2/3 | answer, cites, shows_method |
| denied-write | growth | 3/3 |  |
| duplicate-title-decision | growth | 3/3 |  |
| equipment-calibration-date | growth | 3/3 |  |
| experiment-alias-owner | growth | 2/3 | names_record |
| facilities-deep-aspect | growth | 3/3 |  |
| handbook-deep-passage | growth | 3/3 |  |
| handbook-media-cooling | growth | 2/3 | answer |
| id-number-start-date | core | 3/3 |  |
| mean-per-medium | growth | 1/3 | answer, finished |
| notes-incubators-foaming | growth | 3/3 |  |
| od-interval-latest | growth | 3/3 |  |
| per-medium-documents | growth | 2/3 | finished, links_documents |
| plateau-doubling-time | growth | 3/3 |  |
| project-lead | growth | 3/3 |  |
| protocol-see-also | growth | 3/3 |  |
| replicate-mean | growth | 1/3 | shows_method |
| sample-last-readings | growth | 3/3 |  |
| sample-lineage | growth | 3/3 |  |
| schema-medium-ingredients | core | 3/3 |  |
| summary-document-links | growth | 3/3 |  |
| unknown-supplier | core | 0/3 | finished, says_unknown |

## Failures

### approval-mark-finished, repeat 1 (status turn_limit)

- `approval`: no write was proposed
- `state`: status is 'running', expected 'finished'
- `finished`: ended with status turn_limit
- transcript: `work/approval-mark-finished-1/transcript.md`

### decision-experiments-mean, repeat 3 (status done)

- `answer`: missing EXP-051, EXP-050
- `answer`: no number within 5% of 3.38
- `cites`: no link to the record that holds the answer
- `shows_method`: no query, formula or steps shown
- transcript: `work/decision-experiments-mean-3/transcript.md`

### experiment-alias-owner, repeat 3 (status done)

- `names_record`: EXP-027 appears only inside a document link, or not at all
- transcript: `work/experiment-alias-owner-3/transcript.md`

### handbook-media-cooling, repeat 2 (status done)

- `answer`: missing '45'
- transcript: `work/handbook-media-cooling-2/transcript.md`

### mean-per-medium, repeat 1 (status turn_limit)

- `answer`: missing number(s) 3.4266666666667, 2.9025, 3.902, 3.052
- `finished`: ended with status turn_limit
- transcript: `work/mean-per-medium-1/transcript.md`

### mean-per-medium, repeat 3 (status turn_limit)

- `answer`: missing number(s) 3.4266666666667, 2.9025, 3.902, 3.052
- `answer`: missing YPD, Minimal glucose, Sucrose broth, Molasses medium
- `finished`: ended with status turn_limit
- transcript: `work/mean-per-medium-3/transcript.md`

### per-medium-documents, repeat 3 (status turn_limit)

- `links_documents`: no link to document(s) 266, 267, 268, 269, 270, 271, 272, 274, 275, 279, 280, 282, 283, 284, 285, 287
- `finished`: ended with status turn_limit
- transcript: `work/per-medium-documents-3/transcript.md`

### replicate-mean, repeat 2 (status done)

- `shows_method`: no query, formula or steps shown
- transcript: `work/replicate-mean-2/transcript.md`

### replicate-mean, repeat 3 (status done)

- `shows_method`: no query, formula or steps shown
- transcript: `work/replicate-mean-3/transcript.md`

### unknown-supplier, repeat 1 (status turn_limit)

- `finished`: ended with status turn_limit
- transcript: `work/unknown-supplier-1/transcript.md`

### unknown-supplier, repeat 2 (status turn_limit)

- `finished`: ended with status turn_limit
- transcript: `work/unknown-supplier-2/transcript.md`

### unknown-supplier, repeat 3 (status turn_limit)

- `says_unknown`: does not say the data lacks the answer
- `finished`: ended with status turn_limit
- transcript: `work/unknown-supplier-3/transcript.md`

