
include ../config.unix

CFLAGS+=-I$(LUA_INCDIR)

INSTALL_DATA=install -m644
TARGET?=../util/

ALL=encodings.so hashes.so net.so pposix.so signal.so table.so \
    ringbuffer.so time.so poll.so compat.so strbitop.so \
    struct.so crypto.so

ifdef RANDOM
ALL+=crand.so
endif

.PHONY: all install clean
.SUFFIXES: .c .o .so

all: $(ALL)

install: $(ALL)
	$(INSTALL_DATA) $? $(TARGET)

clean:
	rm -f $(ALL) $(patsubst %.so,%.o,$(ALL))

encodings.o: CFLAGS+=$(IDNA_FLAGS)
encodings.so: LDLIBS+=$(IDNA_LIBS)

crypto.so hashes.so: LDLIBS+=$(OPENSSL_LIBS)

crand.o: CFLAGS+=-DWITH_$(RANDOM)
crand.so: LDLIBS+=$(RANDOM_LIBS)

%.so: %.o
	$(LD) $(LDFLAGS) -o $@ $^ $(LDLIBS)
