all: prosodyctl.man

%.man: %.markdown
	pandoc -s -t man -o $@ $^
