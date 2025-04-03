#!/bin/bash

#set -x

. ../lib.sh

expect_cert "certs/xmpp.example.com.crt" "localhost:5281" "xmpp.example.com" "tls"
expect_cert "certs/example.com.crt" "localhost:5222" "example.com" "xmpp"
expect_cert "certs/example.com.crt" "localhost:5223" "example.com" "xmpps"

# Weirdly configured host, just to test manual override behaviour
expect_cert "certs/example.com.crt" "localhost:5222" "example.net" "xmpp"
expect_cert "certs/example.com.crt" "localhost:5222" "example.net" "xmpp"
expect_cert "certs/example.com.crt" "localhost:5223" "example.net" "tls"
expect_cert "certs/example.com.crt" "localhost:5281" "example.net" "tls"

# Three domains using a single cert with SANs
expect_cert "certs/example.org.crt" "localhost:5222" "example.org" "xmpp"
expect_cert "certs/example.org.crt" "localhost:5223" "example.org" "xmpps"
expect_cert "certs/example.org.crt" "localhost:5269" "example.org" "xmpp-server"
expect_cert "certs/example.org.crt" "localhost:5269" "share.example.org" "xmpp-server"
expect_cert "certs/example.org.crt" "localhost:5269" "groups.example.org" "xmpp-server"
expect_cert "certs/example.org.crt" "localhost:5281" "share.example.org" "tls"

exit "$failures"
