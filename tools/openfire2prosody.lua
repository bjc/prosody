#!/usr/bin/env lua
-- Prosody IM
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

package.path = package.path..";../?.lua";
package.cpath = package.cpath..";../?.so"; -- needed for util.pposix used in datamanager

-- ugly workaround for getting datamanager to work outside of prosody :(
prosody = { };
prosody.platform = "unknown";
if os.getenv("WINDIR") then
	prosody.platform = "windows";
elseif package.config:sub(1,1) == "/" then
	prosody.platform = "posix";
end

local lxp = require "lxp";
local st = require "util.stanza";

local parse_xml = (function()
	local ns_prefixes = {
		["http://www.w3.org/XML/1998/namespace"] = "xml";
	};
	local ns_separator = "\1";
	local ns_pattern = "^([^"..ns_separator.."]*)"..ns_separator.."?(.*)$";
	return function(xml)
		local handler = {};
		local stanza = st.stanza("root");
		function handler:StartElement(tagname, attr)
			local curr_ns,name = tagname:match(ns_pattern);
			if name == "" then
				curr_ns, name = "", curr_ns;
			end
			if curr_ns ~= "" then
				attr.xmlns = curr_ns;
			end
			for i=1,#attr do
				local k = attr[i];
				attr[i] = nil;
				local ns, nm = k:match(ns_pattern);
				if nm ~= "" then
					ns = ns_prefixes[ns]; 
					if ns then 
						attr[ns..":"..nm] = attr[k];
						attr[k] = nil;
					end
				end
			end
			stanza:tag(name, attr);
		end
		function handler:CharacterData(data)
			stanza:text(data);
		end
		function handler:EndElement(tagname)
			stanza:up();
		end
		local parser = lxp.new(handler, "\1");
		local ok, err, line, col = parser:parse(xml);
		if ok then ok, err, line, col = parser:parse(); end
		--parser:close();
		if ok then
			return stanza.tags[1];
		else
			return ok, err.." (line "..line..", col "..col..")";
		end
	end;
end)();

-----------------------------------------------------------------------

package.loaded["util.logger"] = {init = function() return function() end; end}
local dm = require "util.datamanager"
dm.set_data_path("data");

local arg = ...;
local help = "/? -? ? /h -h /help -help --help";
if not arg or help:find(arg, 1, true) then
	print([[Openfire importer for Prosody

  Usage: openfire2prosody.lua filename.xml hostname

]]);
	os.exit(1);
end

local host = select(2, ...) or "localhost";

local file = assert(io.open(arg));
local data = assert(file:read("*a"));
file:close();

local xml = assert(parse_xml(data));

assert(xml.name == "Openfire", "The input file is not an Openfire XML export");

local substatus_mapping = { ["0"] = "none", ["1"] = "to", ["2"] = "from", ["3"] = "both" };

for _,tag in ipairs(xml.tags) do
	if tag.name == "User" then
		local username, password, roster;

		for _,tag in ipairs(tag.tags) do
			if tag.name == "Username" then
				username = tag:get_text();
			elseif tag.name == "Password" then
				password = tag:get_text();
			elseif tag.name == "Roster" then
				roster = {};
				local pending = {};
				for _,tag in ipairs(tag.tags) do
					if tag.name == "Item" then
						local jid = assert(tag.attr.jid, "Roster item has no JID");
						if tag.attr.substatus ~= "-1" then
							local item = {};
							item.name = tag.attr.name;
							item.subscription = assert(substatus_mapping[tag.attr.substatus], "invalid substatus");
							item.ask = tag.attr.askstatus == "0" and "subscribe" or nil;

							local groups = {};
							for _,tag in ipairs(tag) do
								if tag.name == "Group" then
									groups[tag:get_text()] = true;
								end
							end
							item.groups = groups;
							roster[jid] = item;
						end
						if tag.attr.recvstatus == "1" then pending[jid] = true; end
					end
				end

				if next(pending) then
					roster[false] = { pending = pending };
				end
			end
		end

		assert(username and password, "No username or password");

		local ret, err = dm.store(username, host, "accounts", {password = password});
		print("["..(err or "success").."] stored account: "..username.."@"..host.." = "..password);

		if roster then
			local ret, err = dm.store(username, host, "roster", roster);
			print("["..(err or "success").."] stored roster: "..username.."@"..host.." = "..password);
		end
	end
end

