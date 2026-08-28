#!/usr/bin/env bats
# tst/integration/page_shell.bats
# Locks in the layout relationship src/html.lua's PLATFORM_GUTTER/
# PLATFORM_NAV_WIDTH constants exist to guarantee -- see their own
# comments: the main content area's side gutter, the chat widget's own
# right/bottom offset, and the chat panel's stretch-to-nav-edge limits
# must all derive from the *same* numbers, not independently-typed
# literals that only coincidentally agree. Before those constants
# existed, exactly that kind of silent drift is what a human had to
# spot visually and report; these tests catch a regression to that
# same drift automatically instead.

load test_helper.bash

setup() {
    setup_test_env
    "$BIN" init
    read TEST_SESSION_COOKIE TEST_CSRF_TOKEN < <(login_test_user "plainuser" "i")
}

teardown() {
    cleanup_test_env
}

@test "the main content gutter is calc(100% - 2*gutter), not a viewport-relative vw (regression: real gutter collapsing to ~0 on common screen widths)" {
    run_cgi "/"
    [[ "$output" =~ "max-width: min("[0-9]*"px, calc(100% - "[0-9]*"px))" ]]
}

@test "the chat widget's right/bottom offset and its panel's stretch limits share the same gutter and nav-width numbers as the main content area" {
    run_cgi "/"
    # Flattened to one line first -- .platform-nav's own width sits on
    # the line right after its selector, and per-line grep (no -z mode)
    # can't lookbehind/lookahead across that newline otherwise; every
    # other value extracted below already sits on one real line, so
    # flattening first is simpler than mixing grep modes per-pattern.
    flat=$(printf '%s' "$output" | tr '\n' ' ')

    nav_width=$(printf '%s' "$flat" | grep -oP '\.platform-nav \{\s*width: \K[0-9]+(?=px;)')
    gutter_doubled=$(printf '%s' "$flat" | grep -oP 'max-width: min\([0-9]+px, calc\(100% - \K[0-9]+(?=px\)\))')
    chat_right=$(printf '%s' "$flat" | grep -oP '\.platform-chat-widget \{ position: fixed; right: \K[0-9]+(?=px;)')
    chat_bottom=$(printf '%s' "$flat" | grep -oP '\.platform-chat-widget \{ position: fixed; right: [0-9]+px; bottom: \K[0-9]+(?=px;)')
    # max-width has three subtracted terms: the widget's own right
    # gutter, the nav rail's width, and a second gutter -- .platform-container's
    # own left inset *within* .platform-main, on top of the nav rail --
    # matching the exact rectangle the main content area's own visible
    # content occupies, not just up to the nav rail's bare edge.
    panel_max_width_right_gutter=$(printf '%s' "$flat" | grep -oP 'max-width: calc\(100vw - \K[0-9]+(?=px - [0-9]+px - [0-9]+px\);)')
    panel_max_width_nav=$(printf '%s' "$flat" | grep -oP 'max-width: calc\(100vw - [0-9]+px - \K[0-9]+(?=px - [0-9]+px\);)')
    panel_max_width_left_gutter=$(printf '%s' "$flat" | grep -oP 'max-width: calc\(100vw - [0-9]+px - [0-9]+px - \K[0-9]+(?=px\);)')
    panel_max_height_top=$(printf '%s' "$flat" | grep -oP 'max-height: calc\(100vh - \K[0-9]+(?=px - 64px - [0-9]+px\);)')
    panel_max_height_bottom=$(printf '%s' "$flat" | grep -oP 'max-height: calc\(100vh - [0-9]+px - 64px - \K[0-9]+(?=px\);)')

    [ -n "$nav_width" ]
    [ -n "$gutter_doubled" ]
    [ -n "$chat_right" ]

    # All of these are the *same* gutter value (PLATFORM_GUTTER).
    [ "$chat_right" -eq "$((gutter_doubled / 2))" ]
    [ "$chat_bottom" -eq "$chat_right" ]
    [ "$panel_max_width_right_gutter" -eq "$chat_right" ]
    [ "$panel_max_width_left_gutter" -eq "$chat_right" ]
    [ "$panel_max_height_top" -eq "$chat_right" ]
    [ "$panel_max_height_bottom" -eq "$chat_right" ]

    # The panel's own stretch-to-nav-edge width uses the exact same
    # number .platform-nav itself renders as its width -- not a second,
    # independently-typed literal.
    [ "$panel_max_width_nav" -eq "$nav_width" ]
}

@test "the chat panel's min-width is never smaller than its own default width (regression: Send button clipped when shrunk to minimum)" {
    run_cgi "/"
    default_width=$(printf '%s' "$output" | grep -oP 'position: absolute; right: 0; bottom: 64px; width: \K[0-9]+(?=px; height: [0-9]+px;)')
    min_width=$(printf '%s' "$output" | grep -oP 'min-width: \K[0-9]+(?=px; min-height:)')
    [ -n "$default_width" ]
    [ -n "$min_width" ]
    [ "$min_width" -ge "$default_width" ]
}
