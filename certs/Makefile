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
	openssl req -new -key $(lastword $^) \
		-sha256 -utf8 -config $(firstword $^) -out $@

%.csr: %.cnf
	umask 0077 && touch $*.key
	openssl req -new -newkey rsa:$(keysize) -nodes -keyout $*.key \
		-sha256 -utf8 -config $^ -out $@
	@chmod 400 $*.key -c

%.csr: %.key
	openssl req -new -key $^ -utf8 -subj /CN=$* -out $@

%.csr:
	umask 0077 && touch $*.key
	openssl req -new -newkey rsa:$(keysize) -nodes -keyout $*.key \
		-utf8 -subj /CN=$* -out $@
	@chmod 400 $*.key -c

# Self signed
%.crt: %.cnf %.key
	openssl req -new -x509 -key $(lastword $^) -days 365 -sha256 -utf8 \
		-config $(firstword $^) -out $@

%.crt: %.cnf
	umask 0077 && touch $*.key
	openssl req -new -x509 -newkey rsa:$(keysize) -nodes -keyout $*.key \
		-days 365 -sha256 -utf8 -config $(firstword $^) -out $@
	@chmod 400 $*.key -c

%.crt: %.key
	openssl req -new -x509 -nodes -key $^ -days 365 \
		-sha256 -out $@ -utf8 -config $(firstword $^)

%.crt:
	umask 0077 && touch $*.key
	openssl req -new -x509 -newkey rsa:$(keysize) -nodes -keyout $*.key \
		-days 365 -sha256 -out $@ -utf8 -subj /CN=$*
	@chmod 400 $*.key -c

# Generate a config from the example
%.cnf:
	sed 's,example\.com,$*,g' openssl.cnf > $@

%.key:
	openssl genrsa $(keysize) > $@
	@chmod 400 $@
