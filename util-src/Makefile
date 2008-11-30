
include ../config.unix

LUA_SUFFIX?=5.1
LUA_INCDIR?=/usr/include/lua$(LUA_SUFFIX)
LUA_LIB?=lua$(LUA_SUFFIX)
IDN_LIB?=idn
OPENSSL_LIB?=crypto



all: encodings.so hashes.so

install: encodings.so hashes.so
	strip *.so
	cp *.so ../util/
	

clean:
	rm -f *.so
	rm -f ../util/*.so

encodings.so: encodings.c
	gcc $(CFLAGS) encodings.c -I$(LUA_INCDIR) -l$(LUA_LIB) -l$(IDN_LIB) -o encodings.so

hashes.so: hashes.c
	gcc $(CFLAGS) hashes.c -I$(LUA_INCDIR) -l$(LUA_LIB) -l$(OPENSSL_LIB) -o hashes.so
	
