
include ../config.unix

LUA_SUFFIX?=5.1
LUA_INCDIR?=/usr/include/lua$(LUA_SUFFIX)
LUA_LIB?=lua$(LUA_SUFFIX)
IDN_LIB?=idn
OPENSSL_LIB?=crypto
CC?=gcc
CXX?=g++
LD?=gcc
CFLAGS+=-ggdb -I$(LUA_INCDIR)

INSTALL_DATA=install -m644
TARGET?=../util/

ALL=encodings.so hashes.so net.so pposix.so signal.so table.so

.PHONY: all install clean
.SUFFIXES: .c .o .so

all: $(ALL)

install: $(ALL)
	$(INSTALL_DATA) $^ $(TARGET)

clean:
	rm -f $(ALL)

encodings.so: encodings.o
	$(CC) -o $@ $< $(LDFLAGS) $(IDNA_LIBS)

hashes.so: hashes.o
	$(CC) -o $@ $< $(LDFLAGS) -l$(OPENSSL_LIB)

%.so: %.o
	$(LD) $(LDFLAGS) -o $@ $^ $(LDLIBS)
