#!/bin/sh -eux

tag="testing"

if [ "$#" -gt 0 ]; then
	tag="$1"
	shift
fi

containerify="$(command -v podman docker)"

$containerify run -it --rm \
	-v "$PWD:$PWD" \
	-w "$PWD" \
	-v "$HOME/.cache:$PWD/.cache" \
	--entrypoint /bin/bash \
	--userns=keep-id \
	--network \
	host "prosody.im/build-env:$tag" "$@"
