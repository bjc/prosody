#!/bin/bash

#set -x

. ../lib.sh

expect_cert "certs/xmpp.example.com.crt" "localhost:5281" "xmpp.example.com" "tls"
expect_cert "certs/example.com.crt" "localhost:5222" "example.com" "xmpp"

exit "$failures"
