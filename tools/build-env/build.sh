#!/bin/sh -eux

cd "$(dirname "$0")"

containerify="$(command -v podman docker)"

$containerify build -f ./Containerfile --squash \
	--build-arg os="${2:-debian}" \
	--build-arg dist="${1:-testing}" \
	-t "prosody.im/build-env:${1:-testing}"

