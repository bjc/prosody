
include ../../config.unix

BIN = $(DESTDIR)$(PREFIX)/bin
CONFIG = $(DESTDIR)$(SYSCONFDIR)
SOURCE = $(DESTDIR)$(LIBDIR)/prosody
DATA = $(DESTDIR)$(DATADIR)
MAN = $(DESTDIR)$(PREFIX)/share/man

INSTALLEDSOURCE = $(LIBDIR)/prosody
INSTALLEDCONFIG = $(SYSCONFDIR)
INSTALLEDMODULES = $(LIBDIR)/prosody/modules
INSTALLEDDATA = $(DATADIR)

all: prosody-migrator.install migrator.cfg.lua.install prosody-migrator.lua

install: prosody-migrator.install migrator.cfg.lua.install
	install -d $(BIN) $(CONFIG) $(SOURCE)
	install -d $(MAN)/man1
	install -m755 ./prosody-migrator.install $(BIN)/prosody-migrator
	test -e $(CONFIG)/migrator.cfg.lua || install -m644 migrator.cfg.lua.install $(CONFIG)/migrator.cfg.lua

clean:
	rm -f prosody-migrator.install
	rm -f migrator.cfg.lua.install

prosody-migrator.install: prosody-migrator.lua
	sed "1s/\blua\b/$(RUNWITH)/; \
		s|^CFG_SOURCEDIR=.*;$$|CFG_SOURCEDIR='$(INSTALLEDSOURCE)';|; \
		s|^CFG_CONFIGDIR=.*;$$|CFG_CONFIGDIR='$(INSTALLEDCONFIG)';|; \
		s|^CFG_DATADIR=.*;$$|CFG_DATADIR='$(INSTALLEDDATA)';|; \
		s|^CFG_PLUGINDIR=.*;$$|CFG_PLUGINDIR='$(INSTALLEDMODULES)/';|;" \
			< prosody-migrator.lua > prosody-migrator.install

migrator.cfg.lua.install: migrator.cfg.lua
	sed "s|^local data_path = .*;$$|local data_path = '$(INSTALLEDDATA)';|;" \
		< migrator.cfg.lua > migrator.cfg.lua.install
