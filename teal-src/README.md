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


## Files of note

`module.d.tl`
:	Describes the module environment.

