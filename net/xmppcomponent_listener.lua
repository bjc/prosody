-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local hosts = _G.hosts;

local t_concat = table.concat;
local tostring = tostring;
local type = type;
local pairs = pairs;

local lxp = require "lxp";
local logger = require "util.logger";
local config = require "core.configmanager";
local connlisteners = require "net.connlisteners";
local uuid_gen = require "util.uuid".generate;
local jid_split = require "util.jid".split;
local sha1 = require "util.hashes".sha1;
local st = require "util.stanza";
local new_xmpp_stream = require "util.xmppstream".new;

local sessions = {};

local log = logger.init("componentlistener");

local component_listener = { default_port = 5347; default_mode = "*a"; default_interface = config.get("*", "core", "component_interface") or "127.0.0.1" };

local xmlns_component = 'jabber:component:accept';

--- Callbacks/data for xmppstream to handle streams for us ---

local stream_callbacks = { default_ns = xmlns_component };

local xmlns_xmpp_streams = "urn:ietf:params:xml:ns:xmpp-streams";

function stream_callbacks.error(session, error, data, data2)
	if session.destroyed then return; end
	log("warn", "Error processing component stream: "..tostring(error));
	if error == "no-stream" then
		session:close("invalid-namespace");
	elseif error == "parse-error" then
		session.log("warn", "External component %s XML parse error: %s", tostring(session.host), tostring(data));
		session:close("not-well-formed");
	elseif error == "stream-error" then
		local condition, text = "undefined-condition";
		for child in data:children() do
			if child.attr.xmlns == xmlns_xmpp_streams then
				if child.name ~= "text" then
					condition = child.name;
				else
					text = child:get_text();
				end
				if condition ~= "undefined-condition" and text then
					break;
				end
			end
		end
		text = condition .. (text and (" ("..text..")") or "");
		session.log("info", "Session closed by remote with error: %s", text);
		session:close(nil, text);
	end
end

function stream_callbacks.streamopened(session, attr)
	if config.get(attr.to, "core", "component_module") ~= "component" then
		-- Trying to act as a component domain which
		-- hasn't been configured
		session:close{ condition = "host-unknown", text = tostring(attr.to).." does not match any configured external components" };
		return;
	end
	
	-- Note that we don't create the internal component
	-- until after the external component auths successfully

	session.host = attr.to;
	session.streamid = uuid_gen();
	session.notopen = nil;
	
	session.send(st.stanza("stream:stream", { xmlns=xmlns_component,
			["xmlns:stream"]='http://etherx.jabber.org/streams', id=session.streamid, from=session.host }):top_tag());

end

function stream_callbacks.streamclosed(session)
	session.log("debug", "Received </stream:stream>");
	session:close();
end

local core_process_stanza = core_process_stanza;

function stream_callbacks.handlestanza(session, stanza)
	-- Namespaces are icky.
	if not stanza.attr.xmlns and stanza.name == "handshake" then
		stanza.attr.xmlns = xmlns_component;
	end
	if not stanza.attr.xmlns or stanza.attr.xmlns == "jabber:client" then
		local from = stanza.attr.from;
		if from then
			if session.component_validate_from then
				local _, domain = jid_split(stanza.attr.from);
				if domain ~= session.host then
					-- Return error
					session.log("warn", "Component sent stanza with missing or invalid 'from' address");
					session:close{
						condition = "invalid-from";
						text = "Component tried to send from address <"..tostring(from)
							   .."> which is not in domain <"..tostring(session.host)..">";
					};
					return;
				end
			end
		else
			stanza.attr.from = session.host;
		end
		if not stanza.attr.to then
			session.log("warn", "Rejecting stanza with no 'to' address");
			session.send(st.error_reply(stanza, "modify", "bad-request", "Components MUST specify a 'to' address on stanzas"));
			return;
		end
	end
	return core_process_stanza(session, stanza);
end

--- Closing a component connection
local stream_xmlns_attr = {xmlns='urn:ietf:params:xml:ns:xmpp-streams'};
local default_stream_attr = { ["xmlns:stream"] = "http://etherx.jabber.org/streams", xmlns = stream_callbacks.default_ns, version = "1.0", id = "" };
local function session_close(session, reason)
	if session.destroyed then return; end
	local log = session.log or log;
	if session.conn then
		if session.notopen then
			session.send("<?xml version='1.0'?>");
			session.send(st.stanza("stream:stream", default_stream_attr):top_tag());
		end
		if reason then
			if type(reason) == "string" then -- assume stream error
				log("info", "Disconnecting component, <stream:error> is: %s", reason);
				session.send(st.stanza("stream:error"):tag(reason, {xmlns = 'urn:ietf:params:xml:ns:xmpp-streams' }));
			elseif type(reason) == "table" then
				if reason.condition then
					local stanza = st.stanza("stream:error"):tag(reason.condition, stream_xmlns_attr):up();
					if reason.text then
						stanza:tag("text", stream_xmlns_attr):text(reason.text):up();
					end
					if reason.extra then
						stanza:add_child(reason.extra);
					end
					log("info", "Disconnecting component, <stream:error> is: %s", tostring(stanza));
					session.send(stanza);
				elseif reason.name then -- a stanza
					log("info", "Disconnecting component, <stream:error> is: %s", tostring(reason));
					session.send(reason);
				end
			end
		end
		session.send("</stream:stream>");
		session.conn:close();
		component_listener.ondisconnect(session.conn, "stream error");
	end
end

--- Component connlistener
function component_listener.onconnect(conn)
	local _send = conn.write;
	local session = { type = "component", conn = conn, send = function (data) return _send(conn, tostring(data)); end };

	-- Logging functions --
	local conn_name = "jcp"..tostring(conn):match("[a-f0-9]+$");
	session.log = logger.init(conn_name);
	session.close = session_close;
	
	session.log("info", "Incoming Jabber component connection");
	
	local stream = new_xmpp_stream(session, stream_callbacks);
	session.stream = stream;
	
	session.notopen = true;
	
	function session.reset_stream()
		session.notopen = true;
		session.stream:reset();
	end

	function session.data(conn, data)
		local ok, err = stream:feed(data);
		if ok then return; end
		log("debug", "Received invalid XML (%s) %d bytes: %s", tostring(err), #data, data:sub(1, 300):gsub("[\r\n]+", " "):gsub("[%z\1-\31]", "_"));
		session:close("not-well-formed");
	end
	
	session.dispatch_stanza = stream_callbacks.handlestanza;

	sessions[conn] = session;
end
function component_listener.onincoming(conn, data)
	local session = sessions[conn];
	session.data(conn, data);
end
function component_listener.ondisconnect(conn, err)
	local session = sessions[conn];
	if session then
		(session.log or log)("info", "component disconnected: %s (%s)", tostring(session.host), tostring(err));
		if session.on_destroy then session:on_destroy(err); end
		sessions[conn] = nil;
		for k in pairs(session) do
			if k ~= "log" and k ~= "close" then
				session[k] = nil;
			end
		end
		session.destroyed = true;
		session = nil;
	end
end

connlisteners.register('xmppcomponent', component_listener);
