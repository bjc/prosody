
include config.unix

BIN = $(DESTDIR)$(PREFIX)/bin
CONFIG = $(DESTDIR)$(SYSCONFDIR)
MODULES = $(DESTDIR)$(PREFIX)/lib/prosody/modules

SOURCEDIR = $(DESTDIR)$(PREFIX)/lib/prosody

all:
	$(MAKE) all -C util-src

install: prosody
	install -d $(BIN) $(CONFIG) $(MODULES)
	install ./prosody $(BIN)
	install -m644 plugins/* $(MODULES)
	install -m644 prosody.cfg.lua $(CONFIG)
	$(MAKE) install -C util-src

clean:
	$(MAKE) clean -C util-src
