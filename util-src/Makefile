
include ../config.unix

LUA_SUFFIX?=5.1
LUA_INCDIR?=/usr/include/lua$(LUA_SUFFIX)
LUA_LIB?=lua$(LUA_SUFFIX)
IDN_LIB?=idn
OPENSSL_LIB?=crypto
CC?=gcc
CXX?=g++
LD?=gcc

.SUFFIXES: .c .o .so

encodings.o:
	$(CXX) $(CFLAGS) -I$(LUA_INCDIR) -c -o encodings.o encodings.cpp

encodings.so: encodings.o
	MACOSX_DEPLOYMENT_TARGET="10.3"; export MACOSX_DEPLOYMENT_TARGET;
	$(CXX) $(LDFLAGS) $(IDNA_LIBS) -o encodings.so encodings.o -lcrypto

.c.o:
	$(CC) $(CFLAGS) -I$(LUA_INCDIR) -c -o $@ $<

.o.so:
	MACOSX_DEPLOYMENT_TARGET="10.3"; export MACOSX_DEPLOYMENT_TARGET;
	$(LD) $(LDFLAGS) -o $@ $< -lidn -lcrypto

all: encodings.so hashes.so pposix.so signal.so

install: encodings.so hashes.so pposix.so signal.so
	install *.so ../util/

clean:
	rm -f *.o
	rm -f *.so
	rm -f ../util/*.so
