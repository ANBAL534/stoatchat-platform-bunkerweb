#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${STOAT_WEBCLIENT_IMAGE_PUBLISHNAME}" ]; then
    IMAGE="baptisterajaut/stoat-web"
    echo "Warning: STOAT_WEBCLIENT_IMAGE_PUBLISHNAME not set, building as ${IMAGE}" >&2
else
    IMAGE="${STOAT_WEBCLIENT_IMAGE_PUBLISHNAME}"
fi
TAG="${1:-dev}"
REF="${STOAT_WEB_REF:-main}"

if command -v nerdctl &> /dev/null; then
    CTR=nerdctl
elif command -v docker &> /dev/null; then
    CTR=docker
else
    echo "Error: neither nerdctl nor docker found"
    exit 1
fi

echo "Using ${CTR}"
echo "Building ${IMAGE}:${TAG} (ref: ${REF})"

${CTR} build \
    --platform linux/amd64 \
    --build-arg STOAT_WEB_REF="${REF}" \
    --build-arg CACHE_BUST="$(date +%s)" \
    -t "${IMAGE}:${TAG}" \
    "${SCRIPT_DIR}"

echo ""
read -rp "Push ${IMAGE}:${TAG}? [y/N] " answer
if [[ "${answer}" =~ ^[Yy]$ ]]; then
    ${CTR} push "${IMAGE}:${TAG}"
    echo "Pushed ${IMAGE}:${TAG}"
fi
