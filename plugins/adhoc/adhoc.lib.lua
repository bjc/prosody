-- Copyright (C) 2009-2010 Florian Zeitz
--
-- This file is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st, uuid = require "util.stanza", require "util.uuid";

local xmlns_cmd = "http://jabber.org/protocol/commands";

local states = {}

local _M = {};

function _cmdtag(desc, status, sessionid, action)
	local cmd = st.stanza("command", { xmlns = xmlns_cmd, node = desc.node, status = status });
	if sessionid then cmd.attr.sessionid = sessionid; end
	if action then cmd.attr.action = action; end

	return cmd;
end

function _M.new(name, node, handler, permission)
	return { name = name, node = node, handler = handler, cmdtag = _cmdtag, permission = (permission or "user") };
end

function _M.handle_cmd(command, origin, stanza)
	local sessionid = stanza.tags[1].attr.sessionid or uuid.generate();
	local dataIn = {};
	dataIn.to = stanza.attr.to;
	dataIn.from = stanza.attr.from;
	dataIn.action = stanza.tags[1].attr.action or "execute";
	dataIn.form = stanza.tags[1]:child_with_ns("jabber:x:data");

	local data, state = command:handler(dataIn, states[sessionid]);
	states[sessionid] = state;
	local stanza = st.reply(stanza);
	if data.status == "completed" then
		states[sessionid] = nil;
		cmdtag = command:cmdtag("completed", sessionid);
	elseif data.status == "canceled" then
		states[sessionid] = nil;
		cmdtag = command:cmdtag("canceled", sessionid);
	elseif data.status == "error" then
		states[sessionid] = nil;
		stanza = st.error_reply(stanza, data.error.type, data.error.condition, data.error.message);
		origin.send(stanza);
		return true;
	else 
		cmdtag = command:cmdtag("executing", sessionid);
	end

	for name, content in pairs(data) do
		if name == "info" then
			cmdtag:tag("note", {type="info"}):text(content):up();
		elseif name == "warn" then
			cmdtag:tag("note", {type="warn"}):text(content):up();
		elseif name == "error" then
			cmdtag:tag("note", {type="error"}):text(content.message):up();
		elseif name =="actions" then
			local actions = st.stanza("actions");
			for _, action in ipairs(content) do
				if (action == "prev") or (action == "next") or (action == "complete") then
					actions:tag(action):up();
				else
					module:log("error", 'Command "'..command.name..
						'" at node "'..command.node..'" provided an invalid action "'..action..'"');
				end
			end
			cmdtag:add_child(actions);
		elseif name == "form" then
			cmdtag:add_child(content:form());
		elseif name == "result" then
			cmdtag:add_child(content.layout:form(content.data, "result"));
		elseif name == "other" then
			cmdtag:add_child(content);
		end
	end
	stanza:add_child(cmdtag);
	origin.send(stanza);

	return true;
end

return _M;
