
include config.unix

BIN = $(DESTDIR)$(PREFIX)/bin
CONFIG = $(DESTDIR)$(SYSCONFDIR)
MODULES = $(DESTDIR)$(PREFIX)/lib/prosody/modules
SOURCE = $(DESTDIR)$(PREFIX)/lib/prosody
DATA = $(DESTDIR)$(DATADIR)
MAN = $(DESTDIR)$(PREFIX)/share/man

INSTALLEDSOURCE = $(PREFIX)/lib/prosody
INSTALLEDCONFIG = $(SYSCONFDIR)
INSTALLEDMODULES = $(PREFIX)/lib/prosody/modules
INSTALLEDDATA = $(DATADIR)

.PHONY: all clean install

all: prosody.install prosodyctl.install prosody.cfg.lua.install prosody.version
	$(MAKE) -C util-src install
ifeq ($(EXCERTS),yes)
	$(MAKE) -C certs localhost.crt example.com.crt || true
endif

install: prosody.install prosodyctl.install prosody.cfg.lua.install util/encodings.so util/encodings.so util/pposix.so util/signal.so
	install -d $(BIN) $(CONFIG) $(MODULES) $(SOURCE)
	install -m750 -d $(DATA)
	install -d $(MAN)/man1
	install -d $(CONFIG)/certs
	install -d $(SOURCE)/core $(SOURCE)/net $(SOURCE)/util
	install -m755 ./prosody.install $(BIN)/prosody
	install -m755 ./prosodyctl.install $(BIN)/prosodyctl
	install -m644 core/* $(SOURCE)/core
	install -m644 net/*.lua $(SOURCE)/net
	install -d $(SOURCE)/net/http
	install -m644 net/http/*.lua $(SOURCE)/net/http
	install -m644 util/*.lua $(SOURCE)/util
	install -m644 util/*.so $(SOURCE)/util
	install -d $(SOURCE)/util/sasl
	install -m644 util/sasl/* $(SOURCE)/util/sasl
	umask 0022 && cp -r plugins/* $(MODULES)
	install -m644 certs/* $(CONFIG)/certs
	install -m644 man/prosodyctl.man $(MAN)/man1/prosodyctl.1
	test -e $(CONFIG)/prosody.cfg.lua || install -m644 prosody.cfg.lua.install $(CONFIG)/prosody.cfg.lua
	test -e prosody.version && install -m644 prosody.version $(SOURCE)/prosody.version || true
	$(MAKE) install -C util-src

clean:
	rm -f prosody.install
	rm -f prosodyctl.install
	rm -f prosody.cfg.lua.install
	rm -f prosody.version
	$(MAKE) clean -C util-src

util/%.so:
	$(MAKE) install -C util-src

%.install: %
	sed "1s/\blua\b/$(RUNWITH)/; \
		s|^CFG_SOURCEDIR=.*;$$|CFG_SOURCEDIR='$(INSTALLEDSOURCE)';|; \
		s|^CFG_CONFIGDIR=.*;$$|CFG_CONFIGDIR='$(INSTALLEDCONFIG)';|; \
		s|^CFG_DATADIR=.*;$$|CFG_DATADIR='$(INSTALLEDDATA)';|; \
		s|^CFG_PLUGINDIR=.*;$$|CFG_PLUGINDIR='$(INSTALLEDMODULES)/';|;" < $^ > $@

prosody.cfg.lua.install: prosody.cfg.lua.dist
	sed 's|certs/|$(INSTALLEDCONFIG)/certs/|' $^ > $@

prosody.version: $(wildcard prosody.release .hg/dirstate)
	test -e .hg/dirstate && \
		hexdump -n6 -e'6/1 "%02x"' .hg/dirstate > $@ || true
	test -f prosody.release && \
		cp prosody.release $@ || true
