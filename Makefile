
include config.unix

BIN = $(DESTDIR)$(PREFIX)/bin
CONFIG = $(DESTDIR)$(SYSCONFDIR)
MODULES = $(DESTDIR)$(PREFIX)/lib/prosody/modules
SOURCE = $(DESTDIR)$(PREFIX)/lib/prosody

all:
	$(MAKE) all -C util-src

install: prosody util/encodings.so util/encodings.so

	install -d $(BIN) $(CONFIG) $(MODULES) $(SOURCE)
	install -d $(SOURCE)/core $(SOURCE)/net $(SOURCE)/util
	install ./prosody $(BIN)
	install -m644 core/* $(SOURCE)/core
	install -m644 net/* $(SOURCE)/net
	install -m644 util/* $(SOURCE)/util
	install -m644 plugins/* $(MODULES)
	install -m644 prosody.cfg.lua $(CONFIG)
	$(MAKE) install -C util-src

clean:
	$(MAKE) clean -C util-src

util/encodings.so:
	$(MAKE) install -C util-src

util/hashes.so:
	$(MAKE) install -C util-src
