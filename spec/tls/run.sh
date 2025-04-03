#!/bin/bash

export LUA_PATH="../../../?.lua;;"
export LUA_CPATH="../../../?.so;;"

any_failed=0

for config in config*; do
	echo "# Preparing $config"
	pushd "$config";
	cp ../../../prosody.cfg.lua.dist ./prosody-default.cfg.lua
	echo 'VirtualHost "*" {pidfile = "prosody.pid";log={debug="prosody.log"}}' >> ./prosody-default.cfg.lua
	ln -s ../../../plugins plugins
	mkdir -p certs data
	./prepare.sh
	../../../prosody -D
	sleep 1;
	echo "# Testing $config"
	./assert.sh
	status=$?
	../../../prosodyctl stop
	rm plugins #prosody-default.cfg.lua
	popd
	if [[ "$status" != "0" ]]; then
		echo -n "NOT ";
		any_failed=1
	fi
	echo "OK: $config";
done

if [[ "$any_failed" != "0" ]]; then
	echo "NOT OK: One or more TLS tests failed";
	exit 1;
fi

echo "OK: All TLS tests passed";
exit 0;
