-- Copyright (C) 2009 Thilo Cestonaro
-- Copyright (C) 2009-2011 Florian Zeitz
--
-- This file is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local it = require "util.iterators";
local st = require "util.stanza";
local is_admin = require "core.usermanager".is_admin;
local jid_host = require "util.jid".host;
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
		local hostname = jid_host(from);
		local command = commands[node];
		if (command.permission == "admin" and privileged)
		    or (command.permission == "global_admin" and global_admin)
		    or (command.permission == "local_user" and hostname == module.host)
		    or (command.permission == "any") then
			reply:tag("identity", { name = command.name,
			    category = "automation", type = "command-node" }):up();
			reply:tag("feature", { var = xmlns_cmd }):up();
			reply:tag("feature", { var = "jabber:x:data" }):up();
			event.exists = true;
		else
			origin.send(st.error_reply(stanza, "auth", "forbidden", "This item is not available to you"));
			return true;
		end
	elseif node == xmlns_cmd then
		reply:tag("identity", { name = "Ad-Hoc Commands",
		    category = "automation", type = "command-list" }):up();
		    event.exists = true;
	end
end);

module:hook("host-disco-items-node", function (event)
	local stanza, reply, disco_node = event.stanza, event.reply, event.node;
	if disco_node ~= xmlns_cmd then
		return;
	end

	local from = stanza.attr.from;
	local admin = is_admin(from, stanza.attr.to);
	local global_admin = is_admin(from);
	local hostname = jid_host(from);
	for node, command in it.sorted_pairs(commands) do
		if (command.permission == "admin" and admin)
		    or (command.permission == "global_admin" and global_admin)
		    or (command.permission == "local_user" and hostname == module.host)
		    or (command.permission == "any") then
			reply:tag("item", { name = command.name,
			    node = node, jid = module:get_host() });
			reply:up();
		end
	end
	event.exists = true;
end);

module:hook("iq-set/host/"..xmlns_cmd..":command", function (event)
	local origin, stanza = event.origin, event.stanza;
	local node = stanza.tags[1].attr.node
	local command = commands[node];
	if command then
		local from = stanza.attr.from;
		local admin = is_admin(from, stanza.attr.to);
		local global_admin = is_admin(from);
		local hostname = jid_host(from);
		if (command.permission == "admin" and not admin)
		    or (command.permission == "global_admin" and not global_admin)
		    or (command.permission == "local_user" and hostname ~= module.host) then
			origin.send(st.error_reply(stanza, "auth", "forbidden", "You don't have permission to execute this command"):up()
			    :add_child(commands[node]:cmdtag("canceled")
				:tag("note", {type="error"}):text("You don't have permission to execute this command")));
			return true
		end
		-- User has permission now execute the command
		adhoc_handle_cmd(commands[node], origin, stanza);
		return true;
	end
end, 500);

local function adhoc_added(event)
	local item = event.item;
	-- Dang this was noicy
	module:log("debug", "Command added by mod_%s: %q, %q", item._provided_by or "<unknown module>", item.name, item.node);
	commands[item.node] = item;
end

local function adhoc_removed(event)
	commands[event.item.node] = nil;
end

module:handle_items("adhoc", adhoc_added, adhoc_removed); -- COMPAT pre module:provides() introduced in 0.9
module:handle_items("adhoc-provider", adhoc_added, adhoc_removed);
