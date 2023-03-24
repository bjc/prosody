-- Copyright (C) 2009 Thilo Cestonaro
-- Copyright (C) 2009-2011 Florian Zeitz
--
-- This file is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local it = require "prosody.util.iterators";
local st = require "prosody.util.stanza";
local jid_host = require "prosody.util.jid".host;
local adhoc_handle_cmd = module:require "adhoc".handle_cmd;
local xmlns_cmd = "http://jabber.org/protocol/commands";
local commands = {};

module:add_feature(xmlns_cmd);

local function check_permissions(event, node, command)
	return (command.permission == "check" and module:may("mod_adhoc:"..node, event))
	    or (command.permission == "local_user" and jid_host(event.stanza.attr.from) == module.host)
	    or (command.permission == "any");
end

module:hook("host-disco-info-node", function (event)
	local stanza, origin, reply, node = event.stanza, event.origin, event.reply, event.node;
	if commands[node] then
		local command = commands[node];
		if check_permissions(event, node, command) then
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
	local reply, disco_node = event.reply, event.node;
	if disco_node ~= xmlns_cmd then
		return;
	end

	for node, command in it.sorted_pairs(commands) do
		if check_permissions(event, node, command) then
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
		if not check_permissions(event, node, command) then
			origin.send(st.error_reply(stanza, "auth", "forbidden", "You don't have permission to execute this command"):up()
				:add_child(command:cmdtag("canceled")
				:tag("note", {type="error"}):text("You don't have permission to execute this command")));
			return true
		end
		-- User has permission now execute the command
		adhoc_handle_cmd(command, origin, stanza);
		return true;
	end
end, 500);

local function adhoc_added(event)
	local item = event.item;
	-- Dang this was noisy
	module:log("debug", "Command added by mod_%s: %q, %q", item._provided_by or "<unknown module>", item.name, item.node);
	commands[item.node] = item;
end

local function adhoc_removed(event)
	commands[event.item.node] = nil;
end

module:handle_items("adhoc", adhoc_added, adhoc_removed); -- COMPAT pre module:provides() introduced in 0.9
module:handle_items("adhoc-provider", adhoc_added, adhoc_removed);
