#!/bin/bash

certs="./certs"

for domain in {,share.}example.com; do
	openssl req -x509 \
	  -newkey rsa:4096 \
	  -keyout "${certs}/${domain}.key" \
	  -out "${certs}/${domain}.crt" \
	  -sha256 \
	  -days 365 \
	  -nodes \
	  -subj "/CN=${domain}" 2>/dev/null;
done
