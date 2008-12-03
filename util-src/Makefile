
include ../config.unix

LUA_SUFFIX?=5.1
LUA_INCDIR?=/usr/include/lua$(LUA_SUFFIX)
LUA_LIB?=lua$(LUA_SUFFIX)
IDN_LIB?=idn
OPENSSL_LIB?=crypto



all: encodings.so hashes.so

install: encodings.so hashes.so
	install *.so ../util/
	

clean:
	rm -f *.so
	rm -f ../util/*.so

encodings.o: encodings.c
	gcc $(CFLAGS) -I$(LUA_INCDIR) -c -o encodings.o encodings.c
encodings.so: encodings.o
	export MACOSX_DEPLOYMENT_TARGET="10.3"; gcc $(LFLAGS) -o encodings.so encodings.o -L/usr/local/lib -lcrypto -lidn
	

hashes.o: hashes.c
	gcc $(CFLAGS) -I$(LUA_INCDIR) -c -o hashes.o hashes.c
hashes.so: hashes.o
	export MACOSX_DEPLOYMENT_TARGET="10.3"; gcc $(CFLAGS) -o hashes.so hashes.o -L/usr/local/lib -lcrypto -lssl
	
