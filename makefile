
include config.unix

BIN = $(DESTDIR)$(PREFIX)/bin
CONFIG = $(DESTDIR)$(SYSCONFDIR)
MODULES = $(DESTDIR)$(LIBDIR)/prosody/modules
SOURCE = $(DESTDIR)$(LIBDIR)/prosody
DATA = $(DESTDIR)$(DATADIR)
MAN = $(DESTDIR)$(PREFIX)/share/man

INSTALLEDSOURCE = $(LIBDIR)/prosody
INSTALLEDCONFIG = $(SYSCONFDIR)
INSTALLEDMODULES = $(LIBDIR)/prosody/modules
INSTALLEDDATA = $(DATADIR)

INSTALL=install -p
INSTALL_DATA=$(INSTALL) -m644
INSTALL_EXEC=$(INSTALL) -m755
MKDIR=install -d
MKDIR_PRIVATE=$(MKDIR) -m750

LUACHECK=luacheck
BUSTED=busted

.PHONY: all test clean install

all: prosody.install prosodyctl.install prosody.cfg.lua.install prosody.version
	$(MAKE) -C util-src install
.if $(EXCERTS) == "yes"
	$(MAKE) -C certs localhost.crt example.com.crt
.endif

install-etc: prosody.cfg.lua.install
	$(MKDIR) $(CONFIG)
	$(MKDIR) $(CONFIG)/certs
	test -f $(CONFIG)/prosody.cfg.lua || $(INSTALL_DATA) prosody.cfg.lua.install $(CONFIG)/prosody.cfg.lua
.if $(EXCERTS) == "yes"
	$(INSTALL_DATA) certs/localhost.crt certs/localhost.key $(CONFIG)/certs
	$(INSTALL_DATA) certs/example.com.crt certs/example.com.key $(CONFIG)/certs
.endif

install-bin: prosody.install prosodyctl.install
	$(MKDIR) $(BIN)
	$(INSTALL_EXEC) ./prosody.install $(BIN)/prosody
	$(INSTALL_EXEC) ./prosodyctl.install $(BIN)/prosodyctl

install-loader:
	$(MKDIR) $(SOURCE)
	$(INSTALL_DATA) loader.lua $(SOURCE)

install-core:
	$(MKDIR) $(SOURCE)
	$(MKDIR) $(SOURCE)/core
	$(INSTALL_DATA) core/*.lua $(SOURCE)/core

install-net:
	$(MKDIR) $(SOURCE)
	$(MKDIR) $(SOURCE)/net
	$(INSTALL_DATA) net/*.lua $(SOURCE)/net
	$(MKDIR) $(SOURCE)/net/http $(SOURCE)/net/resolvers $(SOURCE)/net/websocket
	$(INSTALL_DATA) net/http/*.lua $(SOURCE)/net/http
	$(INSTALL_DATA) net/resolvers/*.lua $(SOURCE)/net/resolvers
	$(INSTALL_DATA) net/websocket/*.lua $(SOURCE)/net/websocket

install-util: util/encodings.so util/encodings.so util/pposix.so util/signal.so
	$(MKDIR) $(SOURCE)
	$(MKDIR) $(SOURCE)/util
	$(INSTALL_DATA) util/*.lua $(SOURCE)/util
	$(MAKE) install -C util-src
	$(INSTALL_DATA) util/*.so $(SOURCE)/util
	$(MKDIR) $(SOURCE)/util/sasl
	$(INSTALL_DATA) util/sasl/*.lua $(SOURCE)/util/sasl
	$(MKDIR) $(SOURCE)/util/human
	$(INSTALL_DATA) util/human/*.lua $(SOURCE)/util/human
	$(MKDIR) $(SOURCE)/util/prosodyctl
	$(INSTALL_DATA) util/prosodyctl/*.lua $(SOURCE)/util/prosodyctl

install-plugins:
	$(MKDIR) $(MODULES)
	$(MKDIR) $(MODULES)/mod_pubsub $(MODULES)/adhoc $(MODULES)/muc $(MODULES)/mod_mam $(MODULES)/mod_debug_stanzas
	$(INSTALL_DATA) plugins/*.lua $(MODULES)
	$(INSTALL_DATA) plugins/mod_pubsub/*.lua $(MODULES)/mod_pubsub
	$(INSTALL_DATA) plugins/adhoc/*.lua $(MODULES)/adhoc
	$(INSTALL_DATA) plugins/muc/*.lua $(MODULES)/muc
	$(INSTALL_DATA) plugins/mod_mam/*.lua $(MODULES)/mod_mam
	$(INSTALL_DATA) plugins/mod_debug_stanzas/*.lua $(MODULES)/mod_debug_stanzas

install-man:
	$(MKDIR) $(MAN)/man1
	$(INSTALL_DATA) man/prosodyctl.man $(MAN)/man1/prosodyctl.1

install-meta:
	-test -f prosody.version && $(INSTALL_DATA) prosody.version $(SOURCE)/prosody.version

install-data:
	$(MKDIR_PRIVATE) $(DATA)

install: install-util install-net install-core install-plugins install-bin install-etc install-man install-meta install-data install-loader

clean:
	rm -f prosody.install
	rm -f prosodyctl.install
	rm -f prosody.cfg.lua.install
	rm -f prosody.version
	$(MAKE) clean -C util-src

lint:
	$(LUACHECK) -q $$(HGPLAIN= hg files -I '**.lua') prosody prosodyctl
	@echo $$(sed -n '/^\tlocal exclude_files/,/^}/p;' .luacheckrc | sed '1d;$d' | wc -l) files ignored
	shellcheck configure

test:
	$(BUSTED) --lua=$(RUNWITH)


prosody.install: prosody
	sed "1s| lua$$| $(RUNWITH)|; \
		s|^CFG_SOURCEDIR=.*;$$|CFG_SOURCEDIR='$(INSTALLEDSOURCE)';|; \
		s|^CFG_CONFIGDIR=.*;$$|CFG_CONFIGDIR='$(INSTALLEDCONFIG)';|; \
		s|^CFG_DATADIR=.*;$$|CFG_DATADIR='$(INSTALLEDDATA)';|; \
		s|^CFG_PLUGINDIR=.*;$$|CFG_PLUGINDIR='$(INSTALLEDMODULES)/';|;" < prosody > $@

prosodyctl.install: prosodyctl
	sed "1s| lua$$| $(RUNWITH)|; \
		s|^CFG_SOURCEDIR=.*;$$|CFG_SOURCEDIR='$(INSTALLEDSOURCE)';|; \
		s|^CFG_CONFIGDIR=.*;$$|CFG_CONFIGDIR='$(INSTALLEDCONFIG)';|; \
		s|^CFG_DATADIR=.*;$$|CFG_DATADIR='$(INSTALLEDDATA)';|; \
		s|^CFG_PLUGINDIR=.*;$$|CFG_PLUGINDIR='$(INSTALLEDMODULES)/';|;" < prosodyctl > $@

prosody.cfg.lua.install: prosody.cfg.lua.dist
	sed 's|certs/|$(INSTALLEDCONFIG)/certs/|' prosody.cfg.lua.dist > $@

prosody.version:
	if [ -f prosody.release ]; then \
		cp prosody.release $@; \
	elif [ -f .hg_archival.txt ]; then \
		sed -n 's/^node: \(............\).*/\1/p' .hg_archival.txt > $@; \
	elif [ -f .hg/dirstate ]; then \
		hexdump -n6 -e'6/1 "%02x"' .hg/dirstate > $@; \
	else \
		echo unknown > $@; \
	fi
