-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- Based on Kepler Compat-5.1 code
-- Copyright Kepler Project 2004-2006 (http://www.keplerproject.org/compat)
-- $Id: compat-5.1.lua,v 1.22 2006/02/20 21:12:47 carregal Exp $
--

local LUA_DIRSEP = '/'
local LUA_OFSEP = '_'
local OLD_LUA_OFSEP = ''
local POF = 'luaopen_'
local LUA_PATH_MARK = '?'
local LUA_IGMARK = ':'

local assert, error, getfenv, ipairs, loadfile, loadlib, pairs, setfenv, setmetatable, type = assert, error, getfenv, ipairs, loadfile, loadlib, pairs, setfenv, setmetatable, type
local find, format, gfind, gsub, sub = string.find, string.format, string.gfind, string.gsub, string.sub

if package.nonglobal_module then return; end
package.nonglobal_module = true;

local _PACKAGE = package
local _LOADED = package.loaded
local _PRELOAD = package.preload

--
-- looks for a file `name' in given path
--
local function findfile (name, pname)
	name = gsub (name, "%.", LUA_DIRSEP)
	local path = _PACKAGE[pname]
	assert (type(path) == "string", format ("package.%s must be a string", pname))
	for c in gfind (path, "[^;]+") do
		c = gsub (c, "%"..LUA_PATH_MARK, name)
		local f = io.open (c)
		if f then
			f:close ()
			return c
		end
	end
	return nil -- not found
end


--
-- check whether library is already loaded
--
local function loader_preload (name)
	assert (type(name) == "string", format (
		"bad argument #1 to `require' (string expected, got %s)", type(name)))
	assert (type(_PRELOAD) == "table", "`package.preload' must be a table")
	return _PRELOAD[name]
end


--
-- Lua library loader
--
local function loader_Lua (name)
	assert (type(name) == "string", format (
		"bad argument #1 to `require' (string expected, got %s)", type(name)))
	local filename = findfile (name, "path")
	if not filename then
		return false
	end
	local f, err = loadfile (filename)
	if not f then
		error (format ("error loading module `%s' (%s)", name, err))
	end
	return f
end


local function mkfuncname (name)
	name = gsub (name, "^.*%"..LUA_IGMARK, "")
	name = gsub (name, "%.", LUA_OFSEP)
	return POF..name
end

local function old_mkfuncname (name)
	--name = gsub (name, "^.*%"..LUA_IGMARK, "")
	name = gsub (name, "%.", OLD_LUA_OFSEP)
	return POF..name
end

--
-- C library loader
--
local function loader_C (name)
	assert (type(name) == "string", format (
		"bad argument #1 to `require' (string expected, got %s)", type(name)))
	local filename = findfile (name, "cpath")
	if not filename then
		return false
	end
	local funcname = mkfuncname (name)
	local f, err = loadlib (filename, funcname)
	if not f then
		funcname = old_mkfuncname (name)
		f, err = loadlib (filename, funcname)
		if not f then
			error (format ("error loading module `%s' (%s)", name, err))
		end
	end
	return f
end


local function loader_Croot (name)
	local p = gsub (name, "^([^.]*).-$", "%1")
	if p == "" then
		return
	end
	local filename = findfile (p, "cpath")
	if not filename then
		return
	end
	local funcname = mkfuncname (name)
	local f, err, where = loadlib (filename, funcname)
	if f then
		return f
	elseif where ~= "init" then
		error (format ("error loading module `%s' (%s)", name, err))
	end
end

-- create `loaders' table
package.loaders = package.loaders or { loader_preload, loader_Lua, loader_C, loader_Croot, }
local _LOADERS = package.loaders


--
-- iterate over available loaders
--
local function load (name, loaders)
	-- iterate over available loaders
	assert (type (loaders) == "table", "`package.loaders' must be a table")
	for i, loader in ipairs (loaders) do
		local f = loader (name)
		if f then
			return f
		end
	end
	error (format ("module `%s' not found", name))
end

-- sentinel
local sentinel = function () end

local old_require = _G.require;
local dep_path = {};
local current_env = nil;
function _G.require(modname)
	--table.insert(dep_path, modname);
	--if getfenv(2) == getfenv(0) --[[and rawget(_G, "__locked")]] then
	--	print("**** Uh-oh, require called from locked global env at "..table.concat(dep_path, "->"), debug.traceback());
	--end
	if not current_env and rawget(_G, "__locked") then
		_G.prosody.unlock_globals();
		_G.__locked = false;
	end
	local old_current_env;
	old_current_env, current_env = current_env, getfenv(2);
	local ok, ret = pcall(old_require, modname);
	current_env = old_current_env;
	if not current_env and rawget(_G, "__locked") == false then
		_G.prosody.lock_globals();
	end
	--table.remove(dep_path);
	if not ok then error(ret, 0); end
	return ret;
end


-- findtable
local function findtable (t, f)
	assert (type(f)=="string", "not a valid field name ("..tostring(f)..")")
	local ff = f.."."
	local ok, e, w = find (ff, '(.-)%.', 1)
	while ok do
		local nt = rawget (t, w)
		if not nt then
			nt = {}
			t[w] = nt
		elseif type(t) ~= "table" then
			return sub (f, e+1)
		end
		t = nt
		ok, e, w = find (ff, '(.-)%.', e+1)
	end
	return t
end

--
-- new package.seeall function
--
function _PACKAGE.seeall (module)
	local t = type(module)
	assert (t == "table", "bad argument #1 to package.seeall (table expected, got "..t..")")
	local meta = getmetatable (module)
	if not meta then
		meta = {}
		setmetatable (module, meta)
	end
	meta.__index = _G
end


--
-- new module function
--
function _G.module (modname, ...)
	local ns = _LOADED[modname];
	if type(ns) ~= "table" then
		--if not current_env then
		--	print("module outside require for "..modname.." at "..debug.traceback());
		--end
		ns = findtable (current_env or getfenv(2), modname);
		if not ns then
			error (string.format ("name conflict for module '%s'", modname))
		end
		_LOADED[modname] = ns
	end
	if not ns._NAME then
		ns._NAME = modname
		ns._M = ns
		ns._PACKAGE = gsub (modname, "[^.]*$", "")
	end
	setfenv (2, ns)
	for i, f in ipairs (arg) do
		f (ns)
	end
end
