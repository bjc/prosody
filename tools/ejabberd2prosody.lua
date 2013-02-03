#!/usr/bin/env lua
-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



package.path = package.path ..";../?.lua";

if arg[0]:match("[/\\]") then
	package.path = package.path .. ";"..arg[0]:gsub("[^/\\]*$", "?.lua");
end

local erlparse = require "erlparse";

prosody = {};

package.loaded["util.logger"] = {init = function() return function() end; end}
local serialize = require "util.serialization".serialize;
local st = require "util.stanza";
local dm = require "util.datamanager"
dm.set_data_path("data");

function build_stanza(tuple, stanza)
	assert(type(tuple) == "table", "XML node is of unexpected type: "..type(tuple));
	if tuple[1] == "xmlelement" then
		assert(type(tuple[2]) == "string", "element name has type: "..type(tuple[2]));
		assert(type(tuple[3]) == "table", "element attribute array has type: "..type(tuple[3]));
		assert(type(tuple[4]) == "table", "element children array has type: "..type(tuple[4]));
		local name = tuple[2];
		local attr = {};
		for _, a in ipairs(tuple[3]) do
			if type(a[1]) == "string" and type(a[2]) == "string" then attr[a[1]] = a[2]; end
		end
		local up;
		if stanza then stanza:tag(name, attr); up = true; else stanza = st.stanza(name, attr); end
		for _, a in ipairs(tuple[4]) do build_stanza(a, stanza); end
		if up then stanza:up(); else return stanza end
	elseif tuple[1] == "xmlcdata" then
		assert(type(tuple[2]) == "string", "XML CDATA has unexpected type: "..type(tuple[2]));
		stanza:text(tuple[2]);
	else
		error("unknown element type: "..serialize(tuple));
	end
end
function build_time(tuple)
	local Megaseconds,Seconds,Microseconds = unpack(tuple);
	return Megaseconds * 1000000 + Seconds;
end

function vcard(node, host, stanza)
	local ret, err = dm.store(node, host, "vcard", st.preserialize(stanza));
	print("["..(err or "success").."] vCard: "..node.."@"..host);
end
function password(node, host, password)
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
	print("["..(err or "success").."] roster: " ..node.."@"..host.." - "..jid);
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
function privacy(node, host, default, lists)
	local privacy = { lists = {} };
	local count = 0;
	if default then privacy.default = default; end
	for _, inlist in ipairs(lists) do
		local name, items = inlist[1], inlist[2];
		local list = { name = name; items = {}; };
		local orders = {};
		for _, item in pairs(items) do
			repeat
				if item[1] ~= "listitem" then print("[error] privacy: unhandled item: "..tostring(item[1])); break; end
				local _type, value = item[2], item[3];
				if _type == "jid" then
					if type(value) ~= "table" then print("[error] privacy: jid value is not valid: "..tostring(value)); break; end
					local _node, _host, _resource = value[1], value[2], value[3];
					if (type(_node) == "table") then _node = nil; end
					if (type(_host) == "table") then _host = nil; end
					if (type(_resource) == "table") then _resource = nil; end
					value = (_node and _node.."@".._host or _host)..(_resource and "/".._resource or "");
				elseif _type == "none" then
					_type = nil;
					value = nil;
				elseif _type == "group" then
					if type(value) ~= "string" then print("[error] privacy: group value is not string: "..tostring(value)); break; end
				elseif _type == "subscription" then
					if value~="both" and value~="from" and value~="to" and value~="none" then
						print("[error] privacy: subscription value is invalid: "..tostring(value)); break;
					end
				else print("[error] privacy: invalid item type: "..tostring(_type)); break; end
				local action = item[4];
				if action ~= "allow" and action ~= "deny" then print("[error] privacy: unhandled action: "..tostring(action)); break; end
				local order = item[5];
				if type(order) ~= "number" or order<0 then print("[error] privacy: order is not numeric: "..tostring(order)); break; end
				if orders[order] then print("[error] privacy: duplicate order value: "..tostring(order)); break; end
				orders[order] = true;
				local match_all = item[6];
				local match_iq = item[7];
				local match_message = item[8];
				local match_presence_in = item[9];
				local match_presence_out = item[10];
				list.items[#list.items+1] = {
					type = _type;
					value = value;
					action = action;
					order = order;
					message = match_message == "true";
					iq = match_iq == "true";
					["presence-in"] = match_presence_in == "true";
					["presence-out"] = match_presence_out == "true";
				};
			until true;
		end
		table.sort(list.items, function(a, b) return a.order < b.order; end);
		if privacy.lists[list.name] then print("[warn] duplicate privacy list: "..tostring(list.name)); end
		privacy.lists[list.name] = list;
		count = count + 1;
	end
	if default and not privacy.lists[default] then
		if default == "none" then privacy.default = nil;
		else print("[warn] default privacy list doesn't exist: "..tostring(default)); end
	end
	local ret, err = dm.store(node, host, "privacy", privacy);
	print("["..(err or "success").."] privacy: " ..node.."@"..host.." - "..count.." list(s)");
end


local filters = {
	passwd = function(tuple)
		password(tuple[2][1], tuple[2][2], tuple[3]);
	end;
	vcard = function(tuple)
		vcard(tuple[2][1], tuple[2][2], build_stanza(tuple[3]));
	end;
	roster = function(tuple)
		local node = tuple[3][1]; local host = tuple[3][2];
		local contact = (type(tuple[4][1]) == "table") and tuple[4][2] or tuple[4][1].."@"..tuple[4][2];
		local name = tuple[5]; local subscription = tuple[6];
		local ask = tuple[7]; local groups = tuple[8];
		if type(name) ~= type("") then name = nil; end
		if ask == "none" then
			ask = nil;
		elseif ask == "out" then
			ask = "subscribe"
		elseif ask == "in" then
			roster_pending(node, host, contact);
			ask = nil;
		elseif ask == "both" then
			roster_pending(node, host, contact);
			ask = "subscribe";
		else error("Unknown ask type: "..ask); end
		if subscription ~= "both" and subscription ~= "from" and subscription ~= "to" and subscription ~= "none" then error(subscription) end
		local item = {name = name, ask = ask, subscription = subscription, groups = {}};
		for _, g in ipairs(groups) do
			if type(g) == "string" then
				item.groups[g] = true;
			end
		end
		roster(node, host, contact, item);
	end;
	private_storage = function(tuple)
		private_storage(tuple[2][1], tuple[2][2], tuple[2][3], build_stanza(tuple[3]));
	end;
	offline_msg = function(tuple)
		offline_msg(tuple[2][1], tuple[2][2], build_time(tuple[3]), build_stanza(tuple[7]));
	end;
	privacy = function(tuple)
		privacy(tuple[2][1], tuple[2][2], tuple[3], tuple[4]);
	end;
	config = function(tuple)
		if tuple[2] == "hosts" then
			local output = io.output(); io.output("prosody.cfg.lua");
			io.write("-- Configuration imported from ejabberd --\n");
			io.write([[Host "*"
	modules_enabled = {
		"saslauth"; -- Authentication for clients and servers. Recommended if you want to log in.
		"legacyauth"; -- Legacy authentication. Only used by some old clients and bots.
		"roster"; -- Allow users to have a roster. Recommended ;)
		"register"; -- Allow users to register on this server using a client
		"tls"; -- Add support for secure TLS on c2s/s2s connections
		"vcard"; -- Allow users to set vCards
		"private"; -- Private XML storage (for room bookmarks, etc.)
		"version"; -- Replies to server version requests
		"dialback"; -- s2s dialback support
		"uptime";
		"disco";
		"time";
		"ping";
		--"selftests";
	};
]]);
			for _, h in ipairs(tuple[3]) do
				io.write("Host \"" .. h .. "\"\n");
			end
			io.output(output);
			print("prosody.cfg.lua created");
		end
	end;
};

local arg = ...;
local help = "/? -? ? /h -h /help -help --help";
if not arg or help:find(arg, 1, true) then
	print([[ejabberd db dump importer for Prosody

  Usage: ejabberd2prosody.lua filename.txt

The file can be generated from ejabberd using:
  sudo ./bin/ejabberdctl dump filename.txt

Note: The path of ejabberdctl depends on your ejabberd installation, and ejabberd needs to be running for ejabberdctl to work.]]);
	os.exit(1);
end
local count = 0;
local t = {};
for item in erlparse.parseFile(arg) do
	count = count + 1;
	local name = item[1];
	t[name] = (t[name] or 0) + 1;
	--print(count, serialize(item));
	if filters[name] then filters[name](item); end
end
--print(serialize(t));
