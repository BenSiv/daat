#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Stop and remove an existing container/image, if any.
podman stop platform-wip-dev 2>/dev/null || true
podman rm platform-wip-dev 2>/dev/null || true
podman rmi platform-wip-dev 2>/dev/null || true

podman build \
    --tag platform-wip-dev \
    --file "$SCRIPT_DIR/Containerfile" \
    "$SCRIPT_DIR"

# Bind-mount the repo checkout itself -- the container has the
# toolchain (luam, build headers), the repo stays on the host, so
# edits made in your normal editor are what actually gets built.
podman run \
    --interactive --tty --rm --name platform-wip-dev \
    --hostname platform-wip-dev \
    --volume "$REPO_DIR:/root/platform-wip" \
    platform-wip-dev
