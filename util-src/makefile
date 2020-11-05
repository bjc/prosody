include ../config.unix

CFLAGS+=-I$(LUA_INCDIR)

INSTALL_DATA=install -m644
TARGET?=../util/

ALL=encodings.so hashes.so net.so pposix.so signal.so table.so \
    ringbuffer.so time.so poll.so compat.so strbitop.so

.ifdef $(RANDOM)
ALL+=crand.so
.endif

.PHONY: all install clean
.SUFFIXES: .c .o .so

all: $(ALL)

install: $(ALL)
	$(INSTALL_DATA) $(ALL) $(TARGET)

clean:
	rm -f $(ALL) $(patsubst %.so,%.o,$(ALL))

encodings.o: encodings.c
	$(CC) $(CFLAGS) $(IDNA_FLAGS) -c -o $@ $<
encodings.so: encodings.o
	$(LD) $(LDFLAGS) -o $@ $< $(LDLIBS) $(IDNA_LIBS)

hashes.so: hashes.o
	$(LD) $(LDFLAGS) -o $@ $< $(LDLIBS) $(OPENSSL_LIBS)

crand.o: crand.c
	$(CC) $(CFLAGS) -DWITH_$(RANDOM) -c -o $@ $<

crand.so: crand.o
	$(LD) $(LDFLAGS) -o $@ $< $(LDLIBS) $(RANDOM_LIBS)

%.so: %.o
	$(LD) $(LDFLAGS) -o $@ $< $(LDLIBS)

.c.o:
	$(CC) $(CFLAGS) -c -o $@ $<

.o.so:
	$(LD) $(LDFLAGS) -o $@ $< $(LDLIBS)
