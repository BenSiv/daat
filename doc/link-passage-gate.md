# The co-retrieval link gate

How daat decides which co-retrieved document pairs are worth asking the model about, and why (brex 355095515).

## The problem

Documents retrieved together often enough (`knowledge.maybe_link_co_retrieved`) are put to the model: is there a real connection, and what is it? A YES writes a connection document linking both.

In a human review of 100 YES verdicts (2026-09-26), only 12 were real connections. Most of the rest shared a subject, not an idea: two papers about cacao, two meeting notes. The claim check (`knowledge.unverified_claims`) already catches invented citations and ids, 12 of the 88. It can't catch a plausible reason about a shared subject.

## The gate

Before the model call, `knowledge.passes_passage_gate` measures how closely the two documents share an idea somewhere in them: the cosine of their **most similar pair of passages** (`passage.best_pair`).
- Passages are the same ones search uses (`passage.split`, `doc/passage-retrieval.md`), over each document's title and content, and their embeddings come from the same cache (`document_passage_cache`). A pair seen before costs no new embeddings.
- Whole-document similarity mostly measures shared subject. The best passage pair also finds a small shared idea inside two documents about different things, which is what a connection is.
- A long document compares only `link_gate_passages_per_document` of its passages: the ones sharing the largest share of their words with the other document. At most `link_gate_max_embeds` new embeddings per pair.

A pair below `link_passage_gate` is recorded in `knowledge_link_review` as `dissimilar`, with its score, and the model isn't called. Like a decline, it's looked at again when co-retrieval grows, and the score changes if either document is edited.

When the score can't be measured (no embedding model, a provider failure, nothing embedded within the cap), the model decides as before. The gate never makes judging worse than it was without it.

The claim check still runs after a YES.

## Choosing the threshold

The 100 labelled pairs (`~/documents/reports/2026-09-26-lims-link-redesign/link-quality/labels.json`), scored with `daat knowledge link-score --pairs` on a local copy of their 63 documents, `text-embedding-005`, 2026-10-27:

| | AUC |
|---|---|
| Best passage pair, every passage | 0.918 |
| Best passage pair, capped as deployed (40 per document, 80 new embeddings) | 0.919 |
| Whole-document similarity (2026-09-27, for reference) | 0.925 |

At the deployed cap:

| `link_passage_gate` | Real connections kept (of 12) | Rejected pairs still passing (of 84) |
|---|---|---|
| 0.65 | 10 | 17 |
| 0.70 | 10 | 10 |
| **0.72 (default)** | **10** | **7** |
| 0.75 | 8 | 3 |
| 0.80 | 4 | 0 |

0.72 stops 77 of the 84 rejected pairs before any model call, and loses 2 of the 12 real ones. With only 12 positives the numbers are rough: re-measure when more verdicts are reviewed.

Whole-document similarity scored about the same on these labels. The passage pair is used anyway because it measures the thing a connection is (a shared idea, possibly small), not shared subject, and it gives the passages that explain the score.

## Settings (`platform.lua`)

| Setting | Default | |
|---|---|---|
| `link_passage_gate` | 0.72 | Lowest best-passage-pair similarity a pair needs before the model is asked (0: off) |
| `link_gate_passages_per_document` | 40 | Most passages of each document compared |
| `link_gate_max_embeds` | 80 | Most new passage embeddings one pair may request |

## Checking a pair

`daat knowledge link-score <id> <id>` prints the score, the gate's verdict and the two passages. `--pairs <file>` scores every `<id> <id>` line, for measuring a threshold.

## Tests

`tst/integration/link_passage_gate.bats`: a dissimilar pair is stopped without a model call, a similar one is judged as before, the off switch, the fallback when it can't be measured, the cap on a long document, `link-score`.
