#!/bin/sh
rm reports/*.report
exec lua test.lua "$@"
