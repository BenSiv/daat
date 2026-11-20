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

@test "bld/package.lua declares a 40-char luam SHA and dev/Containerfile matches optional luam_pin" {
    luam_dir=$(real_luam_dir)
    min_commit=$("$luam_dir/bin/luam" -e "pkg = dofile(\"$PROJECT_ROOT/bld/package.lua\"); if pkg.luam != nil then print(pkg.luam) end")
    [[ "$min_commit" =~ ^[0-9a-f]{40}$ ]]

    pin=$("$luam_dir/bin/luam" -e "pkg = dofile(\"$PROJECT_ROOT/bld/package.lua\"); if pkg.luam_pin != nil then print(pkg.luam_pin) end")
    expected_ref="${pin:-main}"
    container_ref=$(sed -n 's/^ARG LUAM_REF=//p' "$PROJECT_ROOT/dev/Containerfile" | tr -d '[:space:]')
    [ "$container_ref" = "$expected_ref" ]
}

@test "lib/static/build.lua refuses a LUAM_DIR checkout missing or behind bld/package.lua luam floor" {
    luam_dir=$(real_luam_dir)
    min_commit=$("$luam_dir/bin/luam" -e "pkg = dofile(\"$PROJECT_ROOT/bld/package.lua\"); print(pkg.luam)")

    mkdir -p "$TEST_DIR/unrelated-luam/obj"
    git init -q "$TEST_DIR/unrelated-luam"
    git -C "$TEST_DIR/unrelated-luam" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "unrelated"
    touch "$TEST_DIR/unrelated-luam/obj/liblua.a"

    cd "$PROJECT_ROOT"
    run env LUA_PATH="$luam_dir/lib/?.lua;$luam_dir/lib/?/init.lua;;" \
        LUA_CPATH="$luam_dir/lib/?.so;$luam_dir/lib/?/?.so;;" \
        "$luam_dir/bin/luam" "$luam_dir/lib/static/build.lua" --luamdir "$TEST_DIR/unrelated-luam"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "does not contain required commit $min_commit" ]]

    if git -C "$luam_dir" rev-parse --verify "${min_commit}~1^{commit}" >/dev/null 2>&1; then
        git clone -q --shared --no-checkout "$luam_dir" "$TEST_DIR/behind-luam"
        git -C "$TEST_DIR/behind-luam" checkout -q --detach "${min_commit}~1"
        mkdir -p "$TEST_DIR/behind-luam/obj"
        touch "$TEST_DIR/behind-luam/obj/liblua.a"

        run env LUA_PATH="$luam_dir/lib/?.lua;$luam_dir/lib/?/init.lua;;" \
            LUA_CPATH="$luam_dir/lib/?.so;$luam_dir/lib/?/?.so;;" \
            "$luam_dir/bin/luam" "$luam_dir/lib/static/build.lua" --luamdir "$TEST_DIR/behind-luam"
        [ "$status" -eq 1 ]
        [[ "$output" =~ "does not contain required commit $min_commit" ]]
    fi
}

@test "optional luam_pin in package manifest enforces exact commit match unless LUAM_ALLOW_MISMATCH=1" {
    luam_dir=$(real_luam_dir)
    min_commit=$("$luam_dir/bin/luam" -e "pkg = dofile(\"$PROJECT_ROOT/bld/package.lua\"); print(pkg.luam)")

    git clone -q --shared --no-checkout "$luam_dir" "$TEST_DIR/ahead-luam"
    git -C "$TEST_DIR/ahead-luam" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "ahead of exact pin"
    mkdir -p "$TEST_DIR/ahead-luam/obj"
    touch "$TEST_DIR/ahead-luam/obj/liblua.a"

    cat > "$TEST_DIR/pinned_pkg.lua" <<EOF
return {
    bin = "daat",
    entry = "main.lua",
    luam = "${min_commit}",
    luam_pin = "${min_commit}",
}
EOF

    cd "$PROJECT_ROOT"
    run env LUA_PATH="$luam_dir/lib/?.lua;$luam_dir/lib/?/init.lua;;" \
        LUA_CPATH="$luam_dir/lib/?.so;$luam_dir/lib/?/?.so;;" \
        "$luam_dir/bin/luam" "$luam_dir/lib/static/build.lua" --package "$TEST_DIR/pinned_pkg.lua" --luamdir "$TEST_DIR/ahead-luam"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "does not match exact pin $min_commit" ]]
}

@test ".dockerignore excludes eval-out/, .git, .store/, and bin/ from Docker build contexts" {
    [ -f "$PROJECT_ROOT/.dockerignore" ]
    grep -q '^eval-out/' "$PROJECT_ROOT/.dockerignore"
    grep -q '^\.git$' "$PROJECT_ROOT/.dockerignore"
    grep -q '^\.store/' "$PROJECT_ROOT/.dockerignore"
    grep -q '^bin/' "$PROJECT_ROOT/.dockerignore"
}

@test "dev/Containerfile installs mariadb-server, mariadb-client, nodejs, and python3 required by bld/test.sh" {
    for pkg in mariadb-server mariadb-client nodejs python3; do
        grep -q "[[:space:]]${pkg}\\b" "$PROJECT_ROOT/dev/Containerfile"
    done
}
