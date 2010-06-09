-- Copyright (C) 2009 Thilo Cestonaro
-- 
-- This file is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";
local is_admin = require "core.usermanager".is_admin;
local adhoc_handle_cmd = module:require "adhoc".handle_cmd;
local xmlns_cmd = "http://jabber.org/protocol/commands";
local xmlns_disco = "http://jabber.org/protocol/disco";
local commands = {};

module:add_feature(xmlns_cmd);

module:hook("iq/host/"..xmlns_disco.."#items:query", function (event)
	local origin, stanza = event.origin, event.stanza;
	-- TODO: Is this correct, or should is_admin be changed?
	local privileged = is_admin(stanza.attr.from)
	    or is_admin(stanza.attr.from, stanza.attr.to); 
	if stanza.attr.type == "get" and stanza.tags[1].attr.node
	    and stanza.tags[1].attr.node == xmlns_cmd then
		reply = st.reply(stanza);
		reply:tag("query", { xmlns = xmlns_disco.."#items",
		    node = xmlns_cmd });
		for node, command in pairs(commands) do
			if (command.permission == "admin" and privileged)
			    or (command.permission == "user") then
				reply:tag("item", { name = command.name,
				    node = node, jid = module:get_host() });
				reply:up();
			end
		end
		origin.send(reply);
		return true;
	end
end, 500);

module:hook("iq/host", function (event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type == "set" and stanza.tags[1]
	    and stanza.tags[1].name == "command" then 
		local node = stanza.tags[1].attr.node
		-- TODO: Is this correct, or should is_admin be changed?
		local privileged = is_admin(event.stanza.attr.from)
		    or is_admin(stanza.attr.from, stanza.attr.to);
		if commands[node] then
			if commands[node].permission == "admin"
			    and not privileged then
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

module:hook("item-added/adhoc", function (event)
	commands[event.item.node] = event.item;
end, 500);

module:hook("item-removed/adhoc", function (event)
	commands[event.item.node] = nil;
end, 500);
