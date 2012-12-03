#!/usr/bin/env lua
-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

prosody = {};

package.path = package.path ..";../?.lua";
local serialize = require "util.serialization".serialize;
local st = require "util.stanza";
local parse_xml = require "util.xml".parse;
package.loaded["util.logger"] = {init = function() return function() end; end}
local dm = require "util.datamanager"
dm.set_data_path("data");

function parseFile(filename)
------

local file = nil;
local last = nil;
local line = 1;
local function read(expected)
	local ch;
	if last then
		ch = last; last = nil;
	else
		ch = file:read(1);
		if ch == "\n" then line = line + 1; end
	end
	if expected and ch ~= expected then error("expected: "..expected.."; got: "..(ch or "nil").." on line "..line); end
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

local escapes = {
	["\\0"] = "\0";
	["\\'"] = "'";
	["\\\""] = "\"";
	["\\b"] = "\b";
	["\\n"] = "\n";
	["\\r"] = "\r";
	["\\t"] = "\t";
	["\\Z"] = "\26";
	["\\\\"] = "\\";
	["\\%"] = "%";
	["\\_"] = "_";
}
local function unescape(s)
	return escapes[s] or error("Unknown escape sequence: "..s);
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
	read("`"); read(" ") -- expect this
	if peek() == "(" then -- skip column list
		repeat until read() == ")";
		read(" ");
	end
	for ch in ("VALUES "):gmatch(".") do read(ch); end -- expect this
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
			if t[tname] then
				local t_name = t[tname];
				for i=1,#tuples do
					table.insert(t_name, tuples[i]);
				end
			else
				t[tname] = tuples;
			end
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
		if #data > 0 and #data[1] ~= #m then
			print("[warning] expected "..#m.." columns for table `"..name.."`, found "..#data[1]);
		end
		for i=1,#data do
			local row = data[i];
			for j=1,#m do
				row[m[j]] = row[j];
				row[j] = nil;
			end
		end
	end
end
--print(serialize(t));

for i, row in ipairs(t["users"] or NULL) do
	local node, password = row.username, row.password;
	local ret, err = dm.store(node, host, "accounts", {password = password});
	print("["..(err or "success").."] accounts: "..node.."@"..host);
end

function roster(node, host, jid, item)
	local roster = dm.load(node, host, "roster") or {};
	roster[jid] = item;
	local ret, err = dm.store(node, host, "roster", roster);
	print("["..(err or "success").."] roster: " ..node.."@"..host.." - "..jid);
end
function roster_pending(node, host, jid)
	local roster = dm.load(node, host, "roster") or {};
	roster.pending = roster.pending or {};
	roster.pending[jid] = true;
	local ret, err = dm.store(node, host, "roster", roster);
	print("["..(err or "success").."] roster-pending: " ..node.."@"..host.." - "..jid);
end
function roster_group(node, host, jid, group)
	local roster = dm.load(node, host, "roster") or {};
	local item = roster[jid];
	if not item then print("Warning: No roster item "..jid.." for user "..node..", can't put in group "..group); return; end
	item.groups[group] = true;
	local ret, err = dm.store(node, host, "roster", roster);
	print("["..(err or "success").."] roster-group: " ..node.."@"..host.." - "..jid.." - "..group);
end
function private_storage(node, host, xmlns, stanza)
	local private = dm.load(node, host, "private") or {};
	private[stanza.name..":"..xmlns] = st.preserialize(stanza);
	local ret, err = dm.store(node, host, "private", private);
	print("["..(err or "success").."] private: " ..node.."@"..host.." - "..xmlns);
end
function offline_msg(node, host, t, stanza)
	stanza.attr.stamp = os.date("!%Y-%m-%dT%H:%M:%SZ", t);
	stanza.attr.stamp_legacy = os.date("!%Y%m%dT%H:%M:%S", t);
	local ret, err = dm.list_append(node, host, "offline", st.preserialize(stanza));
	print("["..(err or "success").."] offline: " ..node.."@"..host.." - "..os.date("!%Y-%m-%dT%H:%M:%SZ", t));
end
for i, row in ipairs(t["rosterusers"] or NULL) do
	local node, contact = row.username, row.jid;
	local name = row.nick;
	if name == "" then name = nil; end
	local subscription = row.subscription;
	if subscription == "N" then
		subscription = "none"
	elseif subscription == "B" then
		subscription = "both"
	elseif subscription == "F" then
		subscription = "from"
	elseif subscription == "T" then
		subscription = "to"
	else error("Unknown subscription type: "..subscription) end;
	local ask = row.ask;
	if ask == "N" then
		ask = nil;
	elseif ask == "O" then
		ask = "subscribe";
	elseif ask == "I" then
		roster_pending(node, host, contact);
		ask = nil;
	elseif ask == "B" then
		roster_pending(node, host, contact);
		ask = "subscribe";
	else error("Unknown ask type: "..ask); end
	local item = {name = name, ask = ask, subscription = subscription, groups = {}};
	roster(node, host, contact, item);
end
for i, row in ipairs(t["rostergroups"] or NULL) do
	roster_group(row.username, host, row.jid, row.grp);
end
for i, row in ipairs(t["vcard"] or NULL) do
	local ret, err = dm.store(row.username, host, "vcard", st.preserialize(parse_xml(row.vcard)));
	print("["..(err or "success").."] vCard: "..row.username.."@"..host);
end
for i, row in ipairs(t["private_storage"] or NULL) do
	private_storage(row.username, host, row.namespace, parse_xml(row.data));
end
table.sort(t["spool"] or NULL, function(a,b) return a.seq < b.seq; end); -- sort by sequence number, just in case
local time_offset = os.difftime(os.time(os.date("!*t")), os.time(os.date("*t"))) -- to deal with timezones
local date_parse = function(s)
	local year, month, day, hour, min, sec = s:match("(....)-?(..)-?(..)T(..):(..):(..)");
	return os.time({year=year, month=month, day=day, hour=hour, min=min, sec=sec-time_offset});
end
for i, row in ipairs(t["spool"] or NULL) do
	local stanza = parse_xml(row.xml);
	local last_child = stanza.tags[#stanza.tags];
	if not last_child or last_child ~= stanza[#stanza] then error("Last child of offline message is not a tag"); end
	if last_child.name ~= "x" and last_child.attr.xmlns ~= "jabber:x:delay" then error("Last child of offline message is not a timestamp"); end
	stanza[#stanza], stanza.tags[#stanza.tags] = nil, nil;
	local t = date_parse(last_child.attr.stamp);
	offline_msg(row.username, host, t, stanza);
end
