#!/bin/bash

certs="./certs"

for domain in {,xmpp.}example.com example.net; do
	openssl req -x509 \
	  -newkey rsa:4096 \
	  -keyout "${certs}/${domain}.key" \
	  -out "${certs}/${domain}.crt" \
	  -sha256 \
	  -days 365 \
	  -nodes \
	  -quiet \
	  -subj "/CN=${domain}" 2>/dev/null;
done

for domain in example.org; do
	openssl req -x509 \
	  -newkey rsa:4096 \
	  -keyout "${certs}/${domain}.key" \
	  -out "${certs}/${domain}.crt" \
	  -sha256 \
	  -days 365 \
	  -nodes \
	  -subj "/CN=${domain}" \
	  -addext "subjectAltName = DNS:${domain}, DNS:groups.${domain}, DNS:share.${domain}" \
	  2>/dev/null;
done
