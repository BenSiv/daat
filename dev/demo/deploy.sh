#!/usr/bin/env bash
set -euo pipefail

# Builds this checkout into the demo image (Cloud Build), pushes it as a
# timestamped tag and :latest, then resets the demo VM so its startup
# script pulls and runs the new image. The VM and the image repository
# are the host's own; see dev/demo/README.md.
#
#   PROJECT_ID=<project> ./dev/demo/deploy.sh               # build, then roll out
#   PROJECT_ID=<project> ./dev/demo/deploy.sh --build-only  # build and push only
#
# Env: PROJECT_ID (required), REGION (europe-west3), ZONE (<REGION>-b),
# NAME (daat-demo: the VM, and the image name) and ARTIFACT_REPO (daat).

cd "$(dirname "$0")/../.."
REPO_ROOT=$(pwd)

: "${PROJECT_ID:?set PROJECT_ID to the GCP project the demo runs in}"
REGION="${REGION:-europe-west3}"
ZONE="${ZONE:-${REGION}-b}"
NAME="${NAME:-daat-demo}"
ARTIFACT_REPO="${ARTIFACT_REPO:-daat}"

IMAGE_REPO="${REGION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REPO}/${NAME}"
# The build uploads the working tree, so uncommitted changes go into the
# image too: say so in the tag.
DIRTY=""
if [ -n "$(git status --porcelain)" ]; then
    DIRTY="-dirty"
fi
TAG="$(date -u +%Y%m%dT%H%M%SZ)-$(git rev-parse --short HEAD)${DIRTY}"

echo "Building ${IMAGE_REPO}:${TAG} (and :latest) from $(git rev-parse --abbrev-ref HEAD)"
gcloud builds submit "${REPO_ROOT}" \
    --project "${PROJECT_ID}" \
    --config dev/demo/cloudbuild.yaml \
    --substitutions "_IMAGE_URI=${IMAGE_REPO}:${TAG},_LATEST_URI=${IMAGE_REPO}:latest"

if [ "${1:-}" = "--build-only" ]; then
    exit 0
fi

echo "Resetting ${NAME} (${ZONE}): a few minutes of downtime while it pulls and restarts"
gcloud compute instances reset "${NAME}" --project "${PROJECT_ID}" --zone "${ZONE}"
echo "Follow the boot with:"
echo "  gcloud compute instances get-serial-port-output ${NAME} --project ${PROJECT_ID} --zone ${ZONE} | grep daat-startup | tail -30"
