#!/bin/bash

#set -x

. ../lib.sh

expect_cert "certs/example.com.crt" "localhost:5222" "example.com" "xmpp"
expect_cert "certs/share.example.com.crt" "localhost:5281" "share.example.com" "tls"

exit "$failures"
