#!/bin/sh
which hg >/dev/null || echo "You must have Mercurial (the hg command)"
hg pull http://heavy-horse.co.uk:4000/
