.DEFAULT: localhost.crt
keysize=2048

# How to:
# First, `make yourhost.cnf` which creates a openssl config file.
# Then edit this file and fill in the details you want it to have,
# and add or change hosts and components it should cover.
# Then `make yourhost.key` to create your private key, you can
# include keysize=number to change the size of the key.
# Then you can either `make yourhost.csr` to generate a certificate
# signing request that you can submit to a CA, or `make yourhost.crt`
# to generate a self signed certificate.

.PRECIOUS: %.cnf %.key

# To request a cert
%.csr: %.cnf %.key
	openssl req -new -key $(lastword $^) -out $@ -utf8 -config $(firstword $^)

# Self signed
%.crt: %.cnf %.key
	openssl req -new -x509 -nodes -key $(lastword $^) -days 365 \
		-sha1 -out $@ -utf8 -config $(firstword $^)

%.cnf:
	sed 's,example\.com,$*,g' openssl.cnf > $@

%.key:
	openssl genrsa $(keysize) > $@
	@chmod 400 $@
