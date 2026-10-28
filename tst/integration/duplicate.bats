#!/usr/bin/env bats
# `daat repair duplicates`: copies of the same synced file folded into
# one document (src/duplicate.lua).

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
}

teardown() {
    cleanup_test_env
}

db() {
    sqlite3 .store/store.db "$1"
}

# A paper's text: N distinct words, enough to pass DUPLICATE_MIN_BODY.
# Every `step`-th word is replaced by `swap` (a second extraction of
# the same PDF differs here and there).
paper_text() {
    local seed="$1" step="${2:-0}" swap="${3:-}"
    local i out=""
    for i in $(seq 1 450); do
        if [ "$step" -gt 0 ] && [ $((i % step)) -eq 0 ]; then
            out="$out $swap$i"
        else
            out="$out $seed$i"
        fi
    done
    printf '%s' "$out"
}

# A synced file: the sync's own header, then the text.
synced() {
    local title="$1" folder="$2" item="$3" body="$4"
    "$BIN" entity create document title="$title" external_id="sharepoint:$item" \
        content="> **SharePoint:** [$folder/$title.pdf](https://example.sharepoint.com/$folder)
> Synced daily.

---

$body" >/dev/null
    db "SELECT id FROM document WHERE external_id = 'sharepoint:$item';"
}

@test "repair duplicates --dry-run lists copies of the same file, by text or by title, and writes nothing" {
    lipids=$(paper_text lipid)
    keep=$(synced "Changes in Lipids during Maturation of Beans" "R&D/Danielle" item-1 "$lipids")
    copy=$(synced "cacao L Changes in Lipids during Maturation of Beans" "R&D/Silvia" item-2 "$lipids")
    genome=$(synced "Genome-wide analysis of embryo maturation" "warehouse" item-3 "$(paper_text gene)")
    reextracted=$(synced "2014 Genome-wide analysis of embryo maturation" "R&D/Danielle" item-4 "$(paper_text gene 60 scan)")
    other=$(synced "Changes in Lipids during Maturation of Beans" "R&D/Ian" item-5 "$(paper_text other)")
    "$BIN" entity create document title="My notes" content="$lipids" >/dev/null

    run "$BIN" repair duplicates --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" =~ "would fold #$copy cacao L Changes in Lipids during Maturation of Beans into #$keep Changes in Lipids during Maturation of Beans (same text)" ]]
    [[ "$output" =~ "would fold #$reextracted 2014 Genome-wide analysis of embryo maturation into #$genome Genome-wide analysis of embryo maturation (same title, 9"[0-9]"% of the text shared)" ]]
    [[ ! "$output" =~ "#$other " ]]
    [[ ! "$output" =~ "My notes" ]]
    [[ "$output" =~ "2 paper(s) with copies, 2 copy(ies) would be folded" ]]

    run db "SELECT COUNT(*) FROM document WHERE archived_at IS NOT NULL OR merged_into IS NOT NULL;"
    [ "$output" -eq 0 ]
}

@test "repair duplicates folds a copy: links move to the kept document, the copy is archived as its duplicate, and a rerun finds nothing" {
    lipids=$(paper_text lipid)
    keep=$(synced "Changes in Lipids during Maturation of Beans" "R&D/Danielle" item-1 "$lipids")
    copy=$(synced "cacao L Changes in Lipids during Maturation of Beans" "R&D/Silvia" item-2 "$lipids")
    "$BIN" entity create document title="Lipid review" content="See [[cacao L Changes in Lipids during Maturation of Beans]]." >/dev/null
    review=$(db "SELECT id FROM document WHERE title = 'Lipid review';")
    "$BIN" entity create document title="Changes in Lipids during Maturation of Beans ↔ cacao L Changes in Lipids during Maturation of Beans" \
        content="[[Changes in Lipids during Maturation of Beans]] and [[cacao L Changes in Lipids during Maturation of Beans]]: the same paper." >/dev/null
    connection=$(db "SELECT id FROM document WHERE title LIKE '%↔%';")
    [ "$(db "SELECT to_document_id FROM document_link WHERE from_document_id = $review;")" -eq "$copy" ]
    count_before=$(db "SELECT document_count FROM knowledge_pool_state;")

    run "$BIN" repair duplicates
    [ "$status" -eq 0 ]
    [[ "$output" =~ "folded #$copy" ]]
    [[ "$output" =~ "archived #$connection" ]]
    [[ "$output" =~ "1 paper(s) with copies, 1 copy(ies) folded, 2 link(s) re-pointed, 1 self-connection(s) archived" ]]

    run db "SELECT duplicate_of || ' ' || merged_into || ' ' || (archived_at IS NOT NULL) FROM document WHERE id = $copy;"
    [ "$output" = "$keep $keep 1" ]
    run db "SELECT archived_at IS NULL FROM document WHERE id = $keep;"
    [ "$output" -eq 1 ]
    # The link to the copy now leads to the kept document.
    run db "SELECT to_document_id FROM document_link WHERE from_document_id = $review AND archived_at IS NULL;"
    [ "$output" -eq "$keep" ]
    # The copy left the pool: one fewer document counted, its embedding gone.
    count_after=$(db "SELECT document_count FROM knowledge_pool_state;")
    [ "$count_after" -eq $((count_before - 2)) ]
    run db "SELECT COUNT(*) FROM document_embedding WHERE document_id = $copy;"
    [ "$output" -eq 0 ]

    run "$BIN" repair duplicates
    [[ "$output" =~ "0 paper(s) with copies, 0 copy(ies) folded" ]]
}

@test "repair duplicates keeps two spreadsheets with the same title and most of the text apart: they're versions, not copies" {
    "$BIN" entity create document title="EXPERIMENT 42 DATA" external_id="sharepoint:item-1" \
        content="> **SharePoint:** [R&D/Ian/EXPERIMENT 42 DATA.xlsx](https://example.sharepoint.com/a)

---

$(paper_text cell)" >/dev/null
    "$BIN" entity create document title="EXPERIMENT 42 DATA" external_id="sharepoint:item-2" \
        content="> **SharePoint:** [R&D/Silvia/EXPERIMENT 42 DATA.xlsx](https://example.sharepoint.com/b)

---

$(paper_text cell 60 count)" >/dev/null

    run "$BIN" repair duplicates --dry-run
    [[ "$output" =~ "0 paper(s) with copies, 0 copy(ies) would be folded" ]]
}

@test "repair duplicates leaves pages people wrote alone, even with a synced file's exact text" {
    lipids=$(paper_text lipid)
    "$BIN" entity create document title="My lipid notes" content="$lipids" >/dev/null
    "$BIN" entity create document title="My lipid notes again" content="$lipids" >/dev/null
    synced "Changes in Lipids during Maturation of Beans" "R&D/Danielle" item-1 "$lipids" >/dev/null

    run "$BIN" repair duplicates
    [[ "$output" =~ "0 paper(s) with copies, 0 copy(ies) folded" ]]
    run db "SELECT COUNT(*) FROM document WHERE archived_at IS NOT NULL;"
    [ "$output" -eq 0 ]
}

@test "a re-sync of a folded copy updates it in place and leaves it folded" {
    lipids=$(paper_text lipid)
    keep=$(synced "Changes in Lipids during Maturation of Beans" "R&D/Danielle" item-1 "$lipids")
    copy=$(synced "cacao L Changes in Lipids during Maturation of Beans" "R&D/Silvia" item-2 "$lipids")
    "$BIN" repair duplicates >/dev/null

    "$BIN" entity update document "$copy" content="$lipids (synced again)" >/dev/null
    run db "SELECT merged_into || ' ' || (archived_at IS NOT NULL) FROM document WHERE id = $copy;"
    [ "$output" = "$keep 1" ]
    run "$BIN" repair duplicates
    [[ "$output" =~ "0 paper(s) with copies" ]]
}
