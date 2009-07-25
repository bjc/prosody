#!/usr/bin/env lua
-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

package.path = package.path ..";../?.lua";
local serialize = require "util.serialization".serialize;
local st = require "util.stanza";
package.loaded["util.logger"] = {init = function() return function() end; end}
local dm = require "util.datamanager"
dm.set_data_path("data");

function parseFile(filename)
------

local file = nil;
local last = nil;
local function read(expected)
	local ch;
	if last then
		ch = last; last = nil;
	else ch = file:read(1); end
	if expected and ch ~= expected then error("expected: "..expected.."; got: "..(ch or "nil")); end
	return ch;
end
local function pushback(ch)
	if last then error(); end
	last = ch;
end
local function peek()
	if not last then last = read(); end
	return last;
end

local function unescape(s)
	if s == "\\'" then return "'"; end
	if s == "\\n" then return "\n"; end
	error("Unknown escape sequence: "..s);
end
local function readString()
	read("'");
	local s = "";
	while true do
		local ch = peek();
		if ch == "\\" then
			s = s..unescape(read()..read());
		elseif ch == "'" then
			break;
		else
			s = s..read();
		end
	end
	read("'");
	return s;
end
local function readNonString()
	local s = "";
	while true do
		if peek() == "," or peek() == ")" then
			break;
		else
			s = s..read();
		end
	end
	return tonumber(s);
end
local function readItem()
	if peek() == "'" then
		return readString();
	else
		return readNonString();
	end
end
local function readTuple()
	local items = {}
	read("(");
	while peek() ~= ")" do
		table.insert(items, readItem());
		if peek() == ")" then break; end
		read(",");
	end
	read(")");
	return items;
end
local function readTuples()
	if peek() ~= "(" then read("("); end
	local tuples = {};
	while true do
		table.insert(tuples, readTuple());
		if peek() == "," then read() end
		if peek() == ";" then break; end
	end
	return tuples;
end
local function readTableName()
	local tname = "";
	while peek() ~= "`" do tname = tname..read(); end
	return tname;
end
local function readInsert()
	if peek() == nil then return nil; end
	for ch in ("INSERT INTO `"):gmatch(".") do -- find line starting with this
		if peek() == ch then
			read(); -- found
		else -- match failed, skip line
			while peek() and read() ~= "\n" do end
			return nil;
		end
	end
	local tname = readTableName();
	for ch in ("` VALUES "):gmatch(".") do read(ch); end -- expect this
	local tuples = readTuples();
	read(";"); read("\n");
	return tname, tuples;
end

local function readFile(filename)
	file = io.open(filename);
	if not file then error("File not found: "..filename); os.exit(0); end
	local t = {};
	while true do
		local tname, tuples = readInsert();
		if tname then
			t[tname] = tuples;
		elseif peek() == nil then
			break;
		end
	end
	return t;
end

return readFile(filename);

------
end

local arg, host = ...;
local help = "/? -? ? /h -h /help -help --help";
if not(arg and host) or help:find(arg, 1, true) then
	print([[ejabberd SQL DB dump importer for Prosody

  Usage: ejabberdsql2prosody.lua filename.txt hostname

The file can be generated using mysqldump:
  mysqldump db_name > filename.txt]]);
	os.exit(1);
end
local map = {
	["last"] = {"username", "seconds", "state"};
	["privacy_default_list"] = {"username", "name"};
	["privacy_list"] = {"username", "name", "id"};
	["privacy_list_data"] = {"id", "t", "value", "action", "ord", "match_all", "match_iq", "match_message", "match_presence_in", "match_presence_out"};
	["private_storage"] = {"username", "namespace", "data"};
	["rostergroups"] = {"username", "jid", "grp"};
	["rosterusers"] = {"username", "jid", "nick", "subscription", "ask", "askmessage", "server", "subscribe", "type"};
	["spool"] = {"username", "xml", "seq"};
	["users"] = {"username", "password"};
	["vcard"] = {"username", "vcard"};
	--["vcard_search"] = {};
}
local NULL = {};
local t = parseFile(arg);
for name, data in pairs(t) do
	local m = map[name];
	if m then
		for i=1,#data do
			local row = data[i];
			for j=1,#row do
				row[m[j]] = row[j];
				row[j] = nil;
			end
		end
	end
end

for i, row in ipairs(t["users"] or NULL) do
	local node, password = row.username, row.password;
	local ret, err = dm.store(node, host, "accounts", {password = password});
	print("["..(err or "success").."] accounts: "..node.."@"..host.." = "..password);
end
for i, row in ipairs(t["private_storage"] or NULL) do
	--local node, password = row.username, row.password;
	--local ret, err = dm.store(node, host, "accounts", {password = password});
	--print("["..(err or "success").."] accounts: "..node.."@"..host.." = "..password);
end
