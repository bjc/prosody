-- Copyright (C) 2009-2010 Florian Zeitz
--
-- This file is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st, uuid = require "util.stanza", require "util.uuid";

local xmlns_cmd = "http://jabber.org/protocol/commands";

local states = {}

local _M = {};

local function _cmdtag(desc, status, sessionid, action)
	local cmd = st.stanza("command", { xmlns = xmlns_cmd, node = desc.node, status = status });
	if sessionid then cmd.attr.sessionid = sessionid; end
	if action then cmd.attr.action = action; end

	return cmd;
end

function _M.new(name, node, handler, permission)
	if not permission then
		error "adhoc.new() expects a permission argument, none given"
	end
	if permission == "user" then
		error "the permission mode 'user' has been renamed 'any', please update your code"
	end
	return { name = name, node = node, handler = handler, cmdtag = _cmdtag, permission = permission };
end

function _M.handle_cmd(command, origin, stanza)
	local cmdtag = stanza.tags[1]
	local sessionid = cmdtag.attr.sessionid or uuid.generate();
	local dataIn = {
		to = stanza.attr.to;
		from = stanza.attr.from;
		action = cmdtag.attr.action or "execute";
		form = cmdtag:get_child("x", "jabber:x:data");
	};

	local data, state = command:handler(dataIn, states[sessionid]);
	states[sessionid] = state;
	local cmdreply;
	if data.status == "completed" then
		states[sessionid] = nil;
		cmdreply = command:cmdtag("completed", sessionid);
	elseif data.status == "canceled" then
		states[sessionid] = nil;
		cmdreply = command:cmdtag("canceled", sessionid);
	elseif data.status == "error" then
		states[sessionid] = nil;
		local reply = st.error_reply(stanza, data.error.type, data.error.condition, data.error.message);
		origin.send(reply);
		return true;
	else
		cmdreply = command:cmdtag("executing", sessionid);
		data.actions = data.actions or { "complete" };
	end

	for name, content in pairs(data) do
		if name == "info" then
			cmdreply:tag("note", {type="info"}):text(content):up();
		elseif name == "warn" then
			cmdreply:tag("note", {type="warn"}):text(content):up();
		elseif name == "error" then
			cmdreply:tag("note", {type="error"}):text(content.message):up();
		elseif name == "actions" then
			local actions = st.stanza("actions", { execute = content.default });
			for _, action in ipairs(content) do
				if (action == "prev") or (action == "next") or (action == "complete") then
					actions:tag(action):up();
				else
					module:log("error", "Command %q at node %q provided an invalid action %q",
						command.name, command.node, action);
				end
			end
			cmdreply:add_child(actions);
		elseif name == "form" then
			cmdreply:add_child((content.layout or content):form(content.values));
		elseif name == "result" then
			cmdreply:add_child((content.layout or content):form(content.values, "result"));
		elseif name == "other" then
			cmdreply:add_child(content);
		end
	end
	local reply = st.reply(stanza);
	reply:add_child(cmdreply);
	origin.send(reply);

	return true;
end

return _M;
