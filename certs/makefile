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

${.TARGETS:M*.crt}: 
	openssl req -new -x509 -newkey rsa:$(keysize) -nodes -keyout ${.TARGET:R}.key \
		-days 365 -sha256 -out $@ -utf8 -subj /CN=${.TARGET:R}

.SUFFIXES: .key .crt
