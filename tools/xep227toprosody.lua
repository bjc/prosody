#!/usr/bin/env lua
-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- Copyright (C) 2010      Stefan Gehn
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

-- FIXME: XEP-0227 supports XInclude but luaexpat does not
--
-- XEP-227 elements and their current level of support:
-- Hosts : supported
-- Users : supported
-- Rosters : supported, needs testing
-- Offline Messages : supported, needs testing
-- Private XML Storage : supported, needs testing
-- vCards : supported, needs testing
-- Privacy Lists: UNSUPPORTED
--   http://xmpp.org/extensions/xep-0227.html#privacy-lists
--   mod_privacy uses dm.load(username, host, "privacy"); and stores stanzas 1:1
-- Incoming Subscription Requests : supported

package.path = package.path..";../?.lua";
package.cpath = package.cpath..";../?.so"; -- needed for util.pposix used in datamanager

local my_name = arg[0];
if my_name:match("[/\\]") then
	package.path = package.path..";"..my_name:gsub("[^/\\]+$", "../?.lua");
	package.cpath = package.cpath..";"..my_name:gsub("[^/\\]+$", "../?.so");
end

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
local xmppstream = require "util.xmppstream";
local new_xmpp_handlers = xmppstream.new_sax_handlers;
local dm = require "util.datamanager"
dm.set_data_path("data");

local ns_separator = xmppstream.ns_separator;
local ns_pattern = xmppstream.ns_pattern;

local xmlns_xep227 = "http://www.xmpp.org/extensions/xep-0227.html#ns";

-----------------------------------------------------------------------

function store_vcard(username, host, stanza)
	-- create or update vCard for username@host
	local ret, err = dm.store(username, host, "vcard", st.preserialize(stanza));
	print("["..(err or "success").."] stored vCard: "..username.."@"..host);
end

function store_password(username, host, password)
	-- create or update account for username@host
	local ret, err = dm.store(username, host, "accounts", {password = password});
	print("["..(err or "success").."] stored account: "..username.."@"..host.." = "..password);
end

function store_roster(username, host, roster_items)
	-- fetch current roster-table for username@host if he already has one
	local roster = dm.load(username, host, "roster") or {};
	-- merge imported roster-items with loaded roster
	for item_tag in roster_items:childtags("item") do
		-- jid for this roster-item
		local item_jid = item_tag.attr.jid
		-- validate item stanzas
		if (item_jid ~= "") then
			-- prepare roster item
			-- TODO: is the subscription attribute optional?
			local item = {subscription = item_tag.attr.subscription, groups = {}};
			-- optional: give roster item a real name
			if item_tag.attr.name then
				item.name = item_tag.attr.name;
			end
			-- optional: iterate over group stanzas inside item stanza
			for group_tag in item_tag:childtags("group") do
				local group_name = group_tag:get_text();
				if (group_name ~= "") then
					item.groups[group_name] = true;
				else
					print("[error] invalid group stanza: "..group_tag:pretty_print());
				end
			end
			-- store item in roster
			roster[item_jid] = item;
			print("[success] roster entry: " ..username.."@"..host.." - "..item_jid);
		else
			print("[error] invalid roster stanza: " ..item_tag:pretty_print());
		end

	end
	-- store merged roster-table
	local ret, err = dm.store(username, host, "roster", roster);
	print("["..(err or "success").."] stored roster: " ..username.."@"..host);
end

function store_private(username, host, private_items)
	local private = dm.load(username, host, "private") or {};
	for _, ch in ipairs(private_items.tags) do
		--print("private :"..ch:pretty_print());
		private[ch.name..":"..ch.attr.xmlns] = st.preserialize(ch);
		print("[success] private item: " ..username.."@"..host.." - "..ch.name);
	end
	local ret, err = dm.store(username, host, "private", private);
	print("["..(err or "success").."] stored private: " ..username.."@"..host);
end

function store_offline_messages(username, host, offline_messages)
	-- TODO: maybe use list_load(), append and list_store() instead
	--       of constantly reopening the file with list_append()?
	for ch in offline_messages:childtags("message", "jabber:client") do
		--print("message :"..ch:pretty_print());
		local ret, err = dm.list_append(username, host, "offline", st.preserialize(ch));
		print("["..(err or "success").."] stored offline message: " ..username.."@"..host.." - "..ch.attr.from);
	end
end


function store_subscription_request(username, host, presence_stanza)
	local from_bare = presence_stanza.attr.from;

	-- fetch current roster-table for username@host if he already has one
	local roster = dm.load(username, host, "roster") or {};

	local item = roster[from_bare];
	if item and (item.subscription == "from" or item.subscription == "both") then
		return; -- already subscribed, do nothing
	end

	-- add to table of pending subscriptions
	if not roster.pending then roster.pending = {}; end
	roster.pending[from_bare] = true;

	-- store updated roster-table
	local ret, err = dm.store(username, host, "roster", roster);
	print("["..(err or "success").."] stored subscription request: " ..username.."@"..host.." - "..from_bare);
end

-----------------------------------------------------------------------

local curr_host = "";
local user_name = "";


local cb = {
	stream_tag = "user",
	stream_ns = xmlns_xep227,
};
function cb.streamopened(session, attr)
	session.notopen = false;
	user_name = attr.name;
	store_password(user_name, curr_host, attr.password);
end
function cb.streamclosed(session)
	session.notopen = true;
	user_name = "";
end
function cb.handlestanza(session, stanza)
	--print("Parsed stanza "..stanza.name.." xmlns: "..(stanza.attr.xmlns or ""));
	if (stanza.name == "vCard") and (stanza.attr.xmlns == "vcard-temp") then
		store_vcard(user_name, curr_host, stanza);
	elseif (stanza.name == "query") then
		if (stanza.attr.xmlns == "jabber:iq:roster") then
			store_roster(user_name, curr_host, stanza);
		elseif (stanza.attr.xmlns == "jabber:iq:private") then
			store_private(user_name, curr_host, stanza);
		end
	elseif (stanza.name == "offline-messages") then
		store_offline_messages(user_name, curr_host, stanza);
	elseif (stanza.name == "presence") and (stanza.attr.xmlns == "jabber:client") then
		store_subscription_request(user_name, curr_host, stanza);
	else
		print("UNHANDLED stanza "..stanza.name.." xmlns: "..(stanza.attr.xmlns or ""));
	end
end

local user_handlers = new_xmpp_handlers({ notopen = true }, cb);

-----------------------------------------------------------------------

local lxp_handlers = {
	--count = 0
};

-- TODO: error handling for invalid opening elements if curr_host is empty
function lxp_handlers.StartElement(parser, elementname, attributes)
	local curr_ns, name = elementname:match(ns_pattern);
	if name == "" then
		curr_ns, name = "", curr_ns;
	end
	--io.write("+ ", string.rep(" ", count), name, "  (", curr_ns, ")", "\n")
	--count = count + 1;
	if curr_host ~= "" then
		-- forward to xmlhandlers
		user_handlers.StartElement(parser, elementname, attributes);
	elseif (curr_ns == xmlns_xep227) and (name == "host") then
		curr_host = attributes["jid"]; -- start of host element
		print("Begin parsing host "..curr_host);
	elseif (curr_ns ~= xmlns_xep227) or (name ~= "server-data") then
		io.stderr:write("Unhandled XML element: ", name, "\n");
		os.exit(1);
	end
end

-- TODO: error handling for invalid closing elements if host is empty
function lxp_handlers.EndElement(parser, elementname)
	local curr_ns, name = elementname:match(ns_pattern);
	if name == "" then
		curr_ns, name = "", curr_ns;
	end
	--count = count - 1;
	--io.write("- ", string.rep(" ", count), name, "  (", curr_ns, ")", "\n")
	if curr_host ~= "" then
		if (curr_ns == xmlns_xep227) and (name == "host") then
			print("End parsing host "..curr_host);
			curr_host = "" -- end of host element
		else
			-- forward to xmlhandlers
			user_handlers.EndElement(parser, elementname);
		end
	elseif (curr_ns ~= xmlns_xep227) or (name ~= "server-data") then
		io.stderr:write("Unhandled XML element: ", name, "\n");
		os.exit(1);
	end
end

function lxp_handlers.CharacterData(parser, string)
	if curr_host ~= "" then
		-- forward to xmlhandlers
		user_handlers.CharacterData(parser, string);
	end
end

-----------------------------------------------------------------------

local arg = ...;
local help = "/? -? ? /h -h /help -help --help";
if not arg or help:find(arg, 1, true) then
	print([[XEP-227 importer for Prosody

  Usage: xep227toprosody.lua filename.xml

]]);
	os.exit(1);
end

local file = io.open(arg);
if not file then
	io.stderr:write("Could not open file: ", arg, "\n");
	os.exit(0);
end

local parser = lxp.new(lxp_handlers, ns_separator);
for l in file:lines() do
	parser:parse(l);
end
parser:parse();
parser:close();
file:close();
