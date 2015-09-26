
include ../config.unix

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

encodings.so: LDLIBS+=$(IDNA_LIBS)

hashes.so: LDLIBS+=$(OPENSSL_LIBS)

%.so: %.o
	$(LD) $(LDFLAGS) -o $@ $^ $(LDLIBS)
