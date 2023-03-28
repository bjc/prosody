# Teal definitions and sources

This directory contains files written in the
[Teal](https://github.com/teal-language/tl) language, a typed dialect of
Lua.  There are two kinds of files, `.tl` Teal source code and `.d.tl`
type definitions files for modules written in Lua. The later allows
writing type-aware Teal using regular Lua or C code.

## Setup

The Teal compiler can be installed from LuaRocks using:

```bash
luarocks install tl
```

## Checking types

```bash
tl check teal-src/prosody/util/example.tl
```

Some editors and IDEs also have support, see [text editor
support](https://github.com/teal-language/tl#text-editor-support)


## Compiling to Lua

`GNUmakefile` contains a rule for building Lua files from Teal sources.
It also applies [LuaFormat](https://github.com/Koihik/LuaFormatter) to
make the resulting code more readable, albeit this makes the line
numbers no longer match the original Teal source.  Sometimes minor
`luacheck` issues remain, such as types being represented as unused
tables, which can be removed.

```bash
sensible-editor teal-src/prosody/util/example.tl
# Write some code, remember to run tl check
make util/example.lua
sensible-editor util/example.lua
# Apply any minor tweaks that may be needed
```

## Files of note

`module.d.tl`
:	Describes the module environment.

