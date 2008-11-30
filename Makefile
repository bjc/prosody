
include config.unix

BIN = $(DESTDIR)$(PREFIX)/bin
CONFIG = $(DESTDIR)$(SYSCONFDIR)
MODULES = $(DESTDIR)$(PREFIX)/lib/prosody/modules
SOURCE = $(DESTDIR)$(PREFIX)/lib/prosody
DATA = $(DESTDIR)$(DATADIR)

INSTALLEDSOURCE = $(PREFIX)/lib/prosody
INSTALLEDCONFIG = $(SYSCONFDIR)
INSTALLEDMODULES = $(PREFIX)/lib/prosody/modules
INSTALLEDDATA = $(DATADIR)

all: prosody.install prosody.cfg.lua.install util/encodings.so util/hashes.so

install: prosody.install prosody.cfg.lua.install util/encodings.so util/encodings.so
	install -d $(BIN) $(CONFIG) $(MODULES) $(SOURCE) $(DATA)
	install -d $(CONFIG)/certs
	install -d $(SOURCE)/core $(SOURCE)/net $(SOURCE)/util
	install ./prosody.install $(BIN)/prosody
	install -m644 core/* $(SOURCE)/core
	install -m644 net/* $(SOURCE)/net
	install -m644 util/* $(SOURCE)/util
	install -m644 plugins/* $(MODULES)
	install -m644 certs/* $(CONFIG)/certs
	install -m644 plugins/* $(MODULES)
	test -e $(CONFIG)/prosody.cfg.lua || install -m644 prosody.cfg.lua.install $(CONFIG)/prosody.cfg.lua
	$(MAKE) install -C util-src

clean:
	rm -f prosody.install
	rm -f prosody.cfg.lua.install
	$(MAKE) clean -C util-src

util/encodings.so:
	$(MAKE) install -C util-src

util/hashes.so:
	$(MAKE) install -C util-src

prosody.install: prosody
	sed "s|^CFG_SOURCEDIR=.*;$$|CFG_SOURCEDIR='$(INSTALLEDSOURCE)';|; \
		s|^CFG_CONFIGDIR=.*;$$|CFG_CONFIGDIR='$(INSTALLEDCONFIG)';|; \
		s|^CFG_DATADIR=.*;$$|CFG_DATADIR='$(INSTALLEDDATA)';|; \
		s|^CFG_PLUGINDIR=.*;$$|CFG_PLUGINDIR='$(INSTALLEDMODULES)/';|;" < prosody > prosody.install

prosody.cfg.lua.install:
	sed 's|certs/|$(INSTALLEDCONFIG)/certs/|' prosody.cfg.lua.dist > prosody.cfg.lua.install

