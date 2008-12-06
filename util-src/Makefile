
include ../config.unix

LUA_SUFFIX?=5.1
LUA_INCDIR?=/usr/include/lua$(LUA_SUFFIX)
LUA_LIB?=lua$(LUA_SUFFIX)
IDN_LIB?=idn
OPENSSL_LIB?=crypto



all: encodings.so hashes.so pposix.so

install: encodings.so hashes.so pposix.so
	install *.so ../util/
	

clean:
	rm -f *.so
	rm -f ../util/*.so

encodings.o: encodings.c
	gcc $(CFLAGS) -I$(LUA_INCDIR) -c -o encodings.o encodings.c
encodings.so: encodings.o
	export MACOSX_DEPLOYMENT_TARGET="10.3"; gcc $(LFLAGS) -o encodings.so encodings.o -L/usr/local/lib -llua$(LUA_SUFFIX) -lcrypto -lidn
	

hashes.o: hashes.c
	gcc $(CFLAGS) -I$(LUA_INCDIR) -c -o hashes.o hashes.c
hashes.so: hashes.o
	export MACOSX_DEPLOYMENT_TARGET="10.3"; gcc $(LFLAGS) -o hashes.so hashes.o -L/usr/local/lib -llua$(LUA_SUFFIX) -lcrypto -lssl

pposix.o: pposix.c
	gcc $(CFLAGS) -I$(LUA_INCDIR) -c -o pposix.o pposix.c
pposix.so: pposix.o
	export MACOSX_DEPLOYMENT_TARGET="10.3"; gcc $(LFLAGS) -o pposix.so pposix.o -L/usr/local/lib -llua$(LUA_SUFFIX)
	
