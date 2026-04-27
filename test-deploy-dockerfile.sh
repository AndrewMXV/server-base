#!/usr/bin/env bash
set -euo pipefail

export CI_PROJECT_NAME="${CI_PROJECT_NAME:-server-base-deploy}"

if [ ! -f id_rsa ]; then
  printf 'fake\n' > id_rsa
  chmod 600 id_rsa
fi

env | grep -E '^(CI_|DEBUG=|JOBS=|JOB_TIMEOUT=)' > ci.env
image="deploy/${CI_PROJECT_NAME}:local"

docker build -t "$image" -f Dockerfile.deploy .
docker run --rm \
  --env-file ci.env \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${PWD}/id_rsa:/root/.ssh/id_rsa:ro" \
  "$image" "$@"
