
include ../../config.unix

BIN = $(DESTDIR)$(PREFIX)/bin
CONFIG = $(DESTDIR)$(SYSCONFDIR)
SOURCE = $(DESTDIR)$(PREFIX)/lib/prosody
DATA = $(DESTDIR)$(DATADIR)
MAN = $(DESTDIR)$(PREFIX)/share/man

INSTALLEDSOURCE = $(PREFIX)/lib/prosody
INSTALLEDCONFIG = $(SYSCONFDIR)
INSTALLEDMODULES = $(PREFIX)/lib/prosody/modules
INSTALLEDDATA = $(DATADIR)

SOURCE_FILES = migrator/*.lua

all: prosody-migrator.install migrator.cfg.lua.install prosody-migrator.lua $(SOURCE_FILES)

install: prosody-migrator.install migrator.cfg.lua.install
	install -d $(BIN) $(CONFIG) $(SOURCE) $(SOURCE)/migrator
	install -d $(MAN)/man1
	install -d $(SOURCE)/migrator
	install -m755 ./prosody-migrator.install $(BIN)/prosody-migrator
	install -m644 $(SOURCE_FILES) $(SOURCE)/migrator
	test -e $(CONFIG)/migrator.cfg.lua || install -m644 migrator.cfg.lua.install $(CONFIG)/migrator.cfg.lua

clean:
	rm -f prosody-migrator.install
	rm -f migrator.cfg.lua.install

prosody-migrator.install: prosody-migrator.lua
	sed "1s/\blua\b/$(RUNWITH)/; \
		s|^CFG_SOURCEDIR=.*;$$|CFG_SOURCEDIR='$(INSTALLEDSOURCE)';|; \
		s|^CFG_CONFIGDIR=.*;$$|CFG_CONFIGDIR='$(INSTALLEDCONFIG)';|;" \
			< prosody-migrator.lua > prosody-migrator.install

migrator.cfg.lua.install: migrator.cfg.lua
	sed "s|^local data_path = .*;$$|local data_path = '$(INSTALLEDDATA)';|;" \
		< migrator.cfg.lua > migrator.cfg.lua.install
