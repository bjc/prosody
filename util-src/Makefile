
include ../config.unix

LUA_SUFFIX?=5.1
LUA_INCDIR?=/usr/include/lua$(LUA_SUFFIX)
LUA_LIB?=lua$(LUA_SUFFIX)
IDN_LIB?=idn
OPENSSL_LIB?=crypto
CC?=gcc
CXX?=g++
LD?=gcc
CFLAGS+=-ggdb

.PHONY: all install clean
.SUFFIXES: .c .o .so

all: encodings.so hashes.so net.so pposix.so signal.so table.so

install: encodings.so hashes.so net.so pposix.so signal.so table.so
	install *.so ../util/

clean:
	rm -f *.o
	rm -f *.so
	rm -f ../util/*.so

encodings.so: encodings.o
	MACOSX_DEPLOYMENT_TARGET="10.3"; export MACOSX_DEPLOYMENT_TARGET;
	$(CC) -o $@ $< $(LDFLAGS) $(IDNA_LIBS)

hashes.so: hashes.o
	MACOSX_DEPLOYMENT_TARGET="10.3"; export MACOSX_DEPLOYMENT_TARGET;
	$(CC) -o $@ $< $(LDFLAGS) -l$(OPENSSL_LIB)

.c.o:
	$(CC) $(CFLAGS) -I$(LUA_INCDIR) -c -o $@ $<

.o.so:
	MACOSX_DEPLOYMENT_TARGET="10.3"; export MACOSX_DEPLOYMENT_TARGET;
	$(LD) -o $@ $< $(LDFLAGS)

