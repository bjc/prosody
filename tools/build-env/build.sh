#!/bin/sh -eux

cd "$(dirname "$0")"

containerify="$(command -v podman || command -v docker)"

if [ -z "$containerify" ]; then
	echo "podman or docker required" >&2
	exit 1
fi

$containerify build -f ./Containerfile --squash \
	--build-arg os="${2:-debian}" \
	--build-arg dist="${1:-testing}" \
	-t "prosody.im/build-env:${1:-testing}"

