
include ../config.unix

LUA_SUFFIX?=5.1
LUA_INCDIR?=/usr/include/lua$(LUA_SUFFIX)
LUA_LIB?=lua$(LUA_SUFFIX)
IDN_LIB?=idn
OPENSSL_LIB?=crypto
CC?=gcc
LD?=gcc


all: encodings.so hashes.so pposix.so signal.so

install: encodings.so hashes.so pposix.so signal.so
	install *.so ../util/
	

clean:
	rm -f *.o
	rm -f *.so
	rm -f ../util/*.so

encodings.o: encodings.c
	$(CC) $(CFLAGS) -I$(LUA_INCDIR) -c -o encodings.o encodings.c
encodings.so: encodings.o
	MACOSX_DEPLOYMENT_TARGET="10.3"; export MACOSX_DEPLOYMENT_TARGET;
	$(LD) $(LFLAGS) -o encodings.so encodings.o -L$(LUA_LIBDIR) -llua$(LUA_SUFFIX) -lidn
	

hashes.o: hashes.c
	$(CC) $(CFLAGS) -I$(LUA_INCDIR) -c -o hashes.o hashes.c
hashes.so: hashes.o
	MACOSX_DEPLOYMENT_TARGET="10.3";
	export MACOSX_DEPLOYMENT_TARGET;
	$(LD) $(LFLAGS) -o hashes.so hashes.o -L$(LUA_LIBDIR) -llua$(LUA_SUFFIX) -lcrypto

pposix.o: pposix.c
	$(CC) $(CFLAGS) -I$(LUA_INCDIR) -c -o pposix.o pposix.c
pposix.so: pposix.o
	MACOSX_DEPLOYMENT_TARGET="10.3";
	export MACOSX_DEPLOYMENT_TARGET;
	$(LD) $(LFLAGS) -o pposix.so pposix.o -L$(LUA_LIBDIR) -llua$(LUA_SUFFIX)
	
lsignal.o: lsignal.c
	$(CC) $(CFLAGS) -I$(LUA_INCDIR) -c -o lsignal.o lsignal.c
signal.so: lsignal.o
	MACOSX_DEPLOYMENT_TARGET="10.3";
	export MACOSX_DEPLOYMENT_TARGET;
	$(LD) $(LFLAGS) -o signal.so lsignal.o -L$(LUA_LIBDIR) -llua$(LUA_SUFFIX)
	
