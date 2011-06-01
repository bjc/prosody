-- Copyright (C) 2009 Thilo Cestonaro
-- Copyright (C) 2009-2010 Florian Zeitz
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

module:hook("iq/host/"..xmlns_disco.."#info:query", function (event)
	local origin, stanza = event.origin, event.stanza;
	local node = stanza.tags[1].attr.node;
	if stanza.attr.type == "get" and node then
		if commands[node] then
			local privileged = is_admin(stanza.attr.from, stanza.attr.to);
			if (commands[node].permission == "admin" and privileged)
			    or (commands[node].permission == "user") then
				reply = st.reply(stanza);
				reply:tag("query", { xmlns = xmlns_disco.."#info",
				    node = node });
				reply:tag("identity", { name = commands[node].name,
				    category = "automation", type = "command-node" }):up();
				reply:tag("feature", { var = xmlns_cmd }):up();
				reply:tag("feature", { var = "jabber:x:data" }):up();
			else
				reply = st.error_reply(stanza, "auth", "forbidden", "This item is not available to you");
			end
			origin.send(reply);
			return true;
		elseif node == xmlns_cmd then
			reply = st.reply(stanza);
			reply:tag("query", { xmlns = xmlns_disco.."#info",
			    node = node });
			reply:tag("identity", { name = "Ad-Hoc Commands",
			    category = "automation", type = "command-list" }):up();
			origin.send(reply);
			return true;

		end
	end
end);

module:hook("iq/host/"..xmlns_disco.."#items:query", function (event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type == "get" and stanza.tags[1].attr.node
	    and stanza.tags[1].attr.node == xmlns_cmd then
		local privileged = is_admin(stanza.attr.from, stanza.attr.to);
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

module:hook("iq/host/"..xmlns_cmd..":command", function (event)
	local origin, stanza = event.origin, event.stanza;
	if stanza.attr.type == "set" then
		local node = stanza.tags[1].attr.node
		if commands[node] then
			local privileged = is_admin(stanza.attr.from, stanza.attr.to);
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

local function handle_item_added(item)
	commands[item.node] = item;
end

module:hook("item-added/adhoc", function (event)
	return handle_item_added(event.item);
end, 500);

module:hook("item-removed/adhoc", function (event)
	commands[event.item.node] = nil;
end, 500);

-- Pick up any items that are already added
for _, item in ipairs(module:get_host_items("adhoc")) do
	handle_item_added(item);
end
