#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Stop and remove an existing container/image, if any.
podman stop daat-dev 2>/dev/null || true
podman rm daat-dev 2>/dev/null || true
podman rmi daat-dev 2>/dev/null || true

podman build \
    --tag daat-dev \
    --file "$SCRIPT_DIR/Containerfile" \
    "$SCRIPT_DIR"

# Bind-mount the repo checkout itself -- the container has the
# toolchain (luam, build headers), the repo stays on the host, so
# edits made in your normal editor are what actually gets built.
podman run \
    --interactive --tty --rm --name daat-dev \
    --hostname daat-dev \
    --volume "$REPO_DIR:/root/daat" \
    daat-dev
