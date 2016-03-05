#!/bin/bash

export LUA_PATH="../?.lua;;"
export LUA_CPATH="../?.so;;"

#set -x

if ! which "$RUNWITH"; then
	echo "Unable to find interpreter $RUNWITH";
	exit 1;
fi

if ! $RUNWITH -e 'assert(require"util.json")' 2>/dev/null; then
	echo "Unable to find util.json";
	exit 1;
fi

FAIL=0

for f in json/pass*.json; do
	if ! $RUNWITH -e 'local j=require"util.json" assert(j.decode(io.read("*a"))~=nil)' <"$f" 2>/dev/null; then
		echo "Failed to decode valid JSON: $f";
		FAIL=1
	fi
done

for f in json/fail*.json; do
	if ! $RUNWITH -e 'local j=require"util.json" assert(j.decode(io.read("*a"))==nil)' <"$f" 2>/dev/null; then
		echo "Invalid JSON decoded without error: $f";
		FAIL=1
	fi
done

if [ "$FAIL" == "1" ]; then
	echo "JSON tests failed"
	exit 1;
fi

exit 0;
