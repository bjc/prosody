-- Copyright (C) 2009 Thilo Cestonaro
-- Copyright (C) 2009-2011 Florian Zeitz
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
		local admin = is_admin(stanza.attr.from, stanza.attr.to);
		local global_admin = is_admin(stanza.attr.from);
		reply = st.reply(stanza);
		reply:tag("query", { xmlns = xmlns_disco.."#items",
		    node = xmlns_cmd });
		for node, command in pairs(commands) do
			if (command.permission == "admin" and admin)
			    or (command.permission == "global_admin" and global_admin)
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
			local admin = is_admin(stanza.attr.from, stanza.attr.to);
			local global_admin = is_admin(stanza.attr.from);
			if (commands[node].permission == "admin" and not admin)
			    or (commands[node].permission == "global_admin" and not global_admin) then
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
