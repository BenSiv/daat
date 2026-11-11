#!/usr/bin/env bats

load test_helper.bash

setup() {
    setup_test_env
}

teardown() {
    cleanup_test_env
}

real_luam_dir() {
    if [ -n "${LUAM_DIR:-}" ]; then
        printf '%s' "$LUAM_DIR"
    else
        (cd "${PROJECT_ROOT}/../luam" && pwd)
    fi
}

@test "bld/luam.commit is a 40-char SHA and dev/Containerfile matches it" {
    pin=$(tr -d '[:space:]' < "$PROJECT_ROOT/bld/luam.commit")
    [[ "$pin" =~ ^[0-9a-f]{40}$ ]]

    container_pin=$(sed -n 's/^ARG LUAM_COMMIT=//p' "$PROJECT_ROOT/dev/Containerfile" | tr -d '[:space:]')
    [ "$container_pin" = "$pin" ]
}

@test "bld/build.sh refuses a LUAM_DIR that is not a git checkout, even inside a parent git repo" {
    mkdir -p "$TEST_DIR/enclosing/non-git-luam/obj"
    git init -q "$TEST_DIR/enclosing"
    git -C "$TEST_DIR/enclosing" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "parent"
    touch "$TEST_DIR/enclosing/non-git-luam/obj/liblua.a"

    run env LUAM_DIR="$TEST_DIR/enclosing/non-git-luam" "$PROJECT_ROOT/bld/build.sh"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "is not a git checkout" ]]
    [[ "$output" =~ "bld/luam.commit" ]]
}

@test "bld/build.sh refuses a LUAM_DIR checkout missing or behind bld/luam.commit" {
    pin=$(tr -d '[:space:]' < "$PROJECT_ROOT/bld/luam.commit")

    mkdir -p "$TEST_DIR/unrelated-luam/obj"
    git init -q "$TEST_DIR/unrelated-luam"
    git -C "$TEST_DIR/unrelated-luam" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "unrelated"
    touch "$TEST_DIR/unrelated-luam/obj/liblua.a"

    run env LUAM_DIR="$TEST_DIR/unrelated-luam" "$PROJECT_ROOT/bld/build.sh"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "does not contain required commit ${pin:0:7}" ]]
    [[ "$output" =~ "bld/luam.commit" ]]

    luam_dir=$(real_luam_dir)
    if git -C "$luam_dir" rev-parse --verify "${pin}~1^{commit}" >/dev/null 2>&1; then
        git clone -q --shared --no-checkout "$luam_dir" "$TEST_DIR/behind-luam"
        git -C "$TEST_DIR/behind-luam" checkout -q --detach "${pin}~1"
        mkdir -p "$TEST_DIR/behind-luam/obj"
        touch "$TEST_DIR/behind-luam/obj/liblua.a"

        run env LUAM_DIR="$TEST_DIR/behind-luam" "$PROJECT_ROOT/bld/build.sh"
        [ "$status" -eq 1 ]
        [[ "$output" =~ "does not contain required commit ${pin:0:7}" ]]
    fi
}

@test "bld/build.sh accepts a LUAM_DIR checkout ahead of bld/luam.commit" {
    luam_dir=$(real_luam_dir)
    git clone -q --shared --no-checkout "$luam_dir" "$TEST_DIR/ahead-luam"
    git -C "$TEST_DIR/ahead-luam" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "ahead of pinned commit"

    mkdir -p "$TEST_DIR/ahead-luam/obj" "$TEST_DIR/ahead-luam/bin" "$TEST_DIR/ahead-luam/lib/static"
    touch "$TEST_DIR/ahead-luam/obj/liblua.a" "$TEST_DIR/ahead-luam/lib/static/build.lua"
    cat > "$TEST_DIR/ahead-luam/bin/luam" <<'EOF'
#!/bin/sh
printf 'delegated:%s\n' "$*"
EOF
    chmod +x "$TEST_DIR/ahead-luam/bin/luam"

    run env LUAM_DIR="$TEST_DIR/ahead-luam" "$PROJECT_ROOT/bld/build.sh"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "delegated:" ]]
}
