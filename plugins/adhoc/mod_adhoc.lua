-- Copyright (C) 2009 Thilo Cestonaro
-- Copyright (C) 2009-2011 Florian Zeitz
--
-- This file is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";
local keys = require "util.iterators".keys;
local array_collect = require "util.array".collect;
local is_admin = require "core.usermanager".is_admin;
local jid_split = require "util.jid".split;
local adhoc_handle_cmd = module:require "adhoc".handle_cmd;
local xmlns_cmd = "http://jabber.org/protocol/commands";
local commands = {};

module:add_feature(xmlns_cmd);

module:hook("host-disco-info-node", function (event)
	local stanza, origin, reply, node = event.stanza, event.origin, event.reply, event.node;
	if commands[node] then
		local from = stanza.attr.from;
		local privileged = is_admin(from, stanza.attr.to);
		local global_admin = is_admin(from);
		local username, hostname = jid_split(from);
		local command = commands[node];
		if (command.permission == "admin" and privileged)
		    or (command.permission == "global_admin" and global_admin)
		    or (command.permission == "local_user" and hostname == module.host)
		    or (command.permission == "user") then
			reply:tag("identity", { name = command.name,
			    category = "automation", type = "command-node" }):up();
			reply:tag("feature", { var = xmlns_cmd }):up();
			reply:tag("feature", { var = "jabber:x:data" }):up();
			event.exists = true;
		else
			return origin.send(st.error_reply(stanza, "auth", "forbidden", "This item is not available to you"));
		end
	elseif node == xmlns_cmd then
		reply:tag("identity", { name = "Ad-Hoc Commands",
		    category = "automation", type = "command-list" }):up();
		    event.exists = true;
	end
end);

module:hook("host-disco-items-node", function (event)
	local stanza, origin, reply, node = event.stanza, event.origin, event.reply, event.node;
	if node ~= xmlns_cmd then
		return;
	end

	local from = stanza.attr.from;
	local admin = is_admin(from, stanza.attr.to);
	local global_admin = is_admin(from);
	local username, hostname = jid_split(from);
	local nodes = array_collect(keys(commands)):sort();
	for _, node in ipairs(nodes) do
		local command = commands[node];
		if (command.permission == "admin" and admin)
		    or (command.permission == "global_admin" and global_admin)
		    or (command.permission == "local_user" and hostname == module.host)
		    or (command.permission == "user") then
			reply:tag("item", { name = command.name,
			    node = node, jid = module:get_host() });
			reply:up();
		end
	end
	event.exists = true;
end);

module:hook("iq/host/"..xmlns_cmd..":command", function (event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type == "set" then
		local node = stanza.tags[1].attr.node
		local command = commands[node];
		if command then
			local from = stanza.attr.from;
			local admin = is_admin(from, stanza.attr.to);
			local global_admin = is_admin(from);
			local username, hostname = jid_split(from);
			if (command.permission == "admin" and not admin)
			    or (command.permission == "global_admin" and not global_admin)
			    or (command.permission == "local_user" and hostname ~= module.host) then
				origin.send(st.error_reply(stanza, "auth", "forbidden", "You don't have permission to execute this command"):up()
				    :add_child(commands[node]:cmdtag("canceled")
					:tag("note", {type="error"}):text("You don't have permission to execute this command")));
				return true
			end
			-- User has permission now execute the command
			return adhoc_handle_cmd(commands[node], origin, stanza);
		end
	end
end, 500);

local function adhoc_added(event)
	local item = event.item;
	commands[item.node] = item;
end

local function adhoc_removed(event)
	commands[event.item.node] = nil;
end

module:handle_items("adhoc", adhoc_added, adhoc_removed);
module:handle_items("adhoc-provider", adhoc_added, adhoc_removed);
