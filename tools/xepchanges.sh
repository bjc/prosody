#!/bin/sh -eu

wget -N https://xmpp.org/extensions/xeplist.xml
xml2 <xeplist.xml |
	2csv xep-infos/xep number version |
	grep -v ^xxxx,|
	sort -g > xepinfos.csv

xml2 < doc/doap.xml |
	2csv -d '	' xmpp:SupportedXep @rdf:resource xmpp:version |
	sed -r 's/https?:\/\/xmpp\.org\/extensions\/xep-0*([1-9][0-9]*)\.html/\1/' |
	while read -r xep ver ; do
		grep "^$xep," xepinfos.csv | awk -F, "\$2 != \"$ver\" { print (\"XEP-\"\$1\" updated to \"\$2\" from $ver\") }"
	done
