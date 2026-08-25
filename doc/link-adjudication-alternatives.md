# Link adjudication: LLM judgment vs. auditable rules (under consideration)

Not a redesign in progress -- a design perspective surfaced while comparing notes with [open-ontologies](https://github.com/fabio-rovai/open-ontologies) (Fabio Rovai), an AI-native ontology-engineering MCP server we're evaluating a possible collaboration with. Recorded here because it applies to this codebase's own linking mechanism specifically, independent of anything ontology-domain-specific in that collaboration.

## Current state: an opaque LLM judge

`knowledge.maybe_link_co_retrieved` (`src/knowledge.lua`) links two documents once they've been retrieved together often enough (`knowledge.due_for_link_review`), by sending both to the LLM with a single prompt -- "is this a genuine relationship, or coincidental overlap? reply YES or NO" -- and creating a `document_link` row on YES (`knowledge.record_link_review` also stores the co-retrieval count and the decision, but not *why*). That link then feeds `knowledge.spread_activation`: a linked neighbor gets a smaller heat boost on retrieval, diluted by fan-out and, since `doc/link-strength-redesign.md`'s Phase 3, weighted by that specific edge's own usage-reinforced strength relative to its siblings (`document.weighted_spreading_delta`, the ACT-R "fan effect").

This works, but the judgment itself is a black box: there's no way to inspect *why* two documents were judged related, only that they were. A wrong link can be found (`knowledge.get_link_review`) but not diagnosed -- there's no trace of which signals mattered or how they combined.

## The alternative open-ontologies actually built

open-ontologies faces a structurally similar problem for a different object: matching classes/concepts between two ontology schemas (is `Dog` in one ontology the same as `Canine` in another?), not linking documents. Their own project history describes a deliberate architectural pivot away from an LLM-as-judge design: HNSW-based embedding search is demoted to a *candidate generator*, and the actual accept/reject/borderline verdict comes from FLORA (`src/align_fuzzy.rs`, `src/flora_pipeline.rs` -- implementing the ISWC 2025 paper "FLORA: Fuzzy Logic Over Relational Alignments"): a 10-rule Mamdani fuzzy inference system over structural signals (label Jaccard, parent/sibling/datatype overlap), triangular membership functions, a choice of three t-norms for rule aggregation, and centroid defuzzification to a crisp `[0, 1]` score -- with a full rule trace, so a reviewer can see exactly which rules fired and with what strength for any given verdict.

Their own framing: embedding-free and interpretable, every accept decision traceable back to specific rules -- the opposite tradeoff from an LLM's bare yes/no.

## Why this is worth considering here

The underlying shape is the same in both systems: generate candidates (co-retrieval count here, HNSW there), then adjudicate whether the relationship is real, then materialize an edge (`document_link` here, an alignment entry there) that downstream mechanisms build on (`spread_activation` here, the merged ontology graph there). daat currently takes the LLM-judge branch of that choice for an operation (a real, persistent write to the pool's link graph) where being unable to inspect or explain a wrong decision is a genuine cost, not a cosmetic one.

## Open questions -- not yet scoped

- **Signals wouldn't transfer directly.** FLORA's signals (parent/sibling/datatype overlap) are class-hierarchy-shaped; daat's documents have no such formal structure. Equivalent signals would need to be defined first (title/content similarity, shared entity references, temporal proximity, folder co-location) -- this is real design work, not a drop-in swap.
- **What's actually lost by dropping the LLM.** The LLM judge can catch a genuinely semantic relationship between two lexically dissimilar documents that no fixed signal set would surface. Whether that's worth losing for interpretability is a real tradeoff, not a clear win either way.
- **Whether this is worth its own effort independent of the ontology collaboration.** This isn't blocked on anything ontology-specific -- it could be explored on its own, but hasn't been scoped as an actual task.

## References

- open-ontologies: https://github.com/fabio-rovai/open-ontologies (`src/align_fuzzy.rs`, `src/flora_pipeline.rs`, `docs/alignment.md`)
- daat's own mechanism: `doc/architecture.md`'s "Knowledge pool" section, "Spreading activation" -- and `src/knowledge.lua`'s `maybe_link_co_retrieved`/`spread_activation`.
- `doc/link-strength-redesign.md` -- a separate, complementary design: not whether a link should be *created*, but how strong an already-created one should be at spread time, usage-weighted rather than flat.
