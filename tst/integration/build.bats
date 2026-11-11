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

stub_built_luam() {
    local dir="$1"
    mkdir -p "$dir/obj" "$dir/bin" "$dir/lib/static"
    touch "$dir/obj/liblua.a" "$dir/lib/static/build.lua"
    cat > "$dir/bin/luam" <<'EOF'
#!/bin/sh
printf 'delegated:%s\n' "$*"
EOF
    chmod +x "$dir/bin/luam"
}

@test "bld/luam.commit is a 40-char SHA and dev/Containerfile matches bld/luam.pin" {
    min_commit=$(tr -d '[:space:]' < "$PROJECT_ROOT/bld/luam.commit")
    [[ "$min_commit" =~ ^[0-9a-f]{40}$ ]]

    pin=$(sed 's/#.*//' "$PROJECT_ROOT/bld/luam.pin" | tr -d '[:space:]')
    expected_ref="${pin:-main}"
    container_ref=$(sed -n 's/^ARG LUAM_REF=//p' "$PROJECT_ROOT/dev/Containerfile" | tr -d '[:space:]')
    [ "$container_ref" = "$expected_ref" ]
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
    min_commit=$(tr -d '[:space:]' < "$PROJECT_ROOT/bld/luam.commit")

    mkdir -p "$TEST_DIR/unrelated-luam/obj"
    git init -q "$TEST_DIR/unrelated-luam"
    git -C "$TEST_DIR/unrelated-luam" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "unrelated"
    touch "$TEST_DIR/unrelated-luam/obj/liblua.a"

    run env LUAM_DIR="$TEST_DIR/unrelated-luam" "$PROJECT_ROOT/bld/build.sh"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "does not contain required commit ${min_commit:0:7}" ]]
    [[ "$output" =~ "bld/luam.commit" ]]

    luam_dir=$(real_luam_dir)
    if git -C "$luam_dir" rev-parse --verify "${min_commit}~1^{commit}" >/dev/null 2>&1; then
        git clone -q --shared --no-checkout "$luam_dir" "$TEST_DIR/behind-luam"
        git -C "$TEST_DIR/behind-luam" checkout -q --detach "${min_commit}~1"
        mkdir -p "$TEST_DIR/behind-luam/obj"
        touch "$TEST_DIR/behind-luam/obj/liblua.a"

        run env LUAM_DIR="$TEST_DIR/behind-luam" "$PROJECT_ROOT/bld/build.sh"
        [ "$status" -eq 1 ]
        [[ "$output" =~ "does not contain required commit ${min_commit:0:7}" ]]
    fi
}

@test "bld/build.sh accepts a LUAM_DIR checkout ahead of bld/luam.commit when bld/luam.pin is unset" {
    luam_dir=$(real_luam_dir)
    git clone -q --shared --no-checkout "$luam_dir" "$TEST_DIR/ahead-luam"
    git -C "$TEST_DIR/ahead-luam" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "ahead of minimum commit"
    stub_built_luam "$TEST_DIR/ahead-luam"

    : > "$TEST_DIR/empty.pin"
    run env LUAM_DIR="$TEST_DIR/ahead-luam" LUAM_PIN_FILE="$TEST_DIR/empty.pin" "$PROJECT_ROOT/bld/build.sh"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "delegated:" ]]
}

@test "optional bld/luam.pin enforces exact commit match unless LUAM_ALLOW_MISMATCH=1" {
    min_commit=$(tr -d '[:space:]' < "$PROJECT_ROOT/bld/luam.commit")
    luam_dir=$(real_luam_dir)

    git clone -q --shared --no-checkout "$luam_dir" "$TEST_DIR/pinned-luam"
    git -C "$TEST_DIR/pinned-luam" checkout -q --detach "$min_commit"
    stub_built_luam "$TEST_DIR/pinned-luam"

    printf '%s\n' "$min_commit" > "$TEST_DIR/exact.pin"
    run env LUAM_DIR="$TEST_DIR/pinned-luam" LUAM_PIN_FILE="$TEST_DIR/exact.pin" "$PROJECT_ROOT/bld/build.sh"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "delegated:" ]]

    git -C "$TEST_DIR/pinned-luam" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "ahead of exact pin"
    run env LUAM_DIR="$TEST_DIR/pinned-luam" LUAM_PIN_FILE="$TEST_DIR/exact.pin" "$PROJECT_ROOT/bld/build.sh"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "does not match exact pin $min_commit" ]]

    run env LUAM_DIR="$TEST_DIR/pinned-luam" LUAM_PIN_FILE="$TEST_DIR/exact.pin" LUAM_ALLOW_MISMATCH=1 "$PROJECT_ROOT/bld/build.sh"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "delegated:" ]]
}
