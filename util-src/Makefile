
include ../config.unix

LUA_SUFFIX?=5.1
LUA_INCDIR?=/usr/include/lua$(LUA_SUFFIX)
LUA_LIB?=lua$(LUA_SUFFIX)
IDN_LIB?=idn
OPENSSL_LIB?=crypto
CC?=gcc
LD?=gcc


all: encodings.so hashes.so pposix.so

install: encodings.so hashes.so pposix.so
	install *.so ../util/
	

clean:
	rm -f *.o
	rm -f *.so
	rm -f ../util/*.so

encodings.o: encodings.c
	$(CC) $(CFLAGS) -I$(LUA_INCDIR) -c -o encodings.o encodings.c
encodings.so: encodings.o
	export MACOSX_DEPLOYMENT_TARGET="10.3"; $(LD) $(LFLAGS) -o encodings.so encodings.o -L$(LUA_LIBDIR) -llua$(LUA_SUFFIX) -lidn
	

hashes.o: hashes.c
	$(CC) $(CFLAGS) -I$(LUA_INCDIR) -c -o hashes.o hashes.c
hashes.so: hashes.o
	export MACOSX_DEPLOYMENT_TARGET="10.3"; $(LD) $(LFLAGS) -o hashes.so hashes.o -L$(LUA_LIBDIR) -llua$(LUA_SUFFIX) -lcrypto

pposix.o: pposix.c
	$(CC) $(CFLAGS) -I$(LUA_INCDIR) -c -o pposix.o pposix.c
pposix.so: pposix.o
	export MACOSX_DEPLOYMENT_TARGET="10.3"; $(LD) $(LFLAGS) -o pposix.so pposix.o -L$(LUA_LIBDIR) -llua$(LUA_SUFFIX)
	
