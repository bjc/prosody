-- Prosody IM v0.4
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

if module:get_host_type() ~= "component" then
	error("Don't load mod_component manually, it should be for a component, please see http://prosody.im/doc/components", 0);
end

local t_concat = table.concat;

local connlisteners = require "net.connlisteners";
local cm_register_component = require "core.componentmanager".register_component;
local uuid_gen = require "util.uuid".generate;
local sha1 = require "util.hashes".sha1;
local st = stanza;
local init_xmlhandlers = require "core.xmlhandlers";

local sessions = {};

local log = module._log;

local component_listener = { default_port = 5347; default_mode = "*a"; default_interface = config.get("*", "core", "component_interface") or "127.0.0.1" };

local xmlns_component = 'jabber:component:accept';

--- Callbacks/data for xmlhandlers to handle streams for us ---

local stream_callbacks = { stream_tag = "http://etherx.jabber.org/streams|stream", default_ns = xmlns_component };

function stream_callbacks.error(session, error, data, data2)
	log("warn", "Error processing component stream: "..tostring(error));
	if error == "no-stream" then
		session:close("invalid-namespace");
	elseif error == "xml-parse-error" and data == "unexpected-element-close" then
		session.log("debug", "Unexpected close of '%s' tag", data2);
		session:close("xml-not-well-formed");
	else
		session.log("debug", "External component %s XML parse error: %s", tostring(session.host), tostring(error));
		print(data, debug.traceback())
		session:close("xml-not-well-formed");
	end
end

function stream_callbacks.streamopened(session, attr)
	if config.get(attr.to, "core", "component_module") ~= "component" then
		-- Trying to act as a component domain which 
		-- hasn't been configured
		session:close{ condition = "host-unknown", text = tostring(attr.to).." does not match any configured external components" };
		return;
	end
	
	-- Store the original host (this is used for config, etc.)
	session.user = attr.to;
	-- Set the host for future reference
	session.host = config.get(attr.to, "core", "component_address") or attr.to;
	-- Note that we don't create the internal component 
	-- until after the external component auths successfully

	session.streamid = uuid_gen();
	session.notopen = nil;
	
	session.send(st.stanza("stream:stream", { xmlns=xmlns_component,
			["xmlns:stream"]='http://etherx.jabber.org/streams', id=session.streamid, from=session.host }):top_tag());

end

function stream_callbacks.streamclosed(session)
end

local core_process_stanza = core_process_stanza;

function stream_callbacks.handlestanza(session, stanza)
	-- Namespaces are icky.
	log("warn", "Handing stanza with name %s", stanza.name);
	if stanza.name ~= "handshake" then
		return core_process_stanza(session, stanza);
	else
		handle_component_auth(session, stanza);
	end
end

--- Handle authentication attempts by components
function handle_component_auth(session, stanza)
	if (not session.host) or #stanza.tags > 0 then
		session:close("not-authorized");
		return;
	end
	
	local secret = config.get(session.user, "core", "component_secret");
	if not secret then
		log("warn", "Component attempted to identify as %s, but component_password is not set", session.user);
		session:close("not-authorized");
		return;
	end
	
	local supplied_token = t_concat(stanza);
	local calculated_token = sha1(session.streamid..secret, true);
	if supplied_token:lower() ~= calculated_token:lower() then
		session:close{ condition = "not-authorized", text = "Given token does not match calculated token" };
		return;
	end
	
	
	-- Authenticated now
	
	-- If component not already created for this host, create one now
	if not hosts[session.host].connected then
		local send = session.send;
		session.component_session = cm_register_component(session.host, function (_, data) return send(data); end);
		hosts[session.host].connected = true;
	else
		log("error", "Multiple components bound to the same address, first one wins (TODO: Implement stanza distribution)");
	end
	
	-- Signal successful authentication
	session.send(st.stanza("handshake"));
end

module:add_handler("component", "handshake", xmlns_component, handle_component_auth);

--[[
-- Helper function to deal with errors processing component stanzas
local function handleerr(err) log("error", "Traceback[component]: %s: %s", tostring(err), debug.traceback()); end
function stream_callbacks.handlestanza(a, b)
	xpcall(function () core_process_stanza(a, b) end, handleerr);
end
]]

--- Closing a component connection
local stream_xmlns_attr = {xmlns='urn:ietf:params:xml:ns:xmpp-streams'};
local function session_close(session, reason)
	local log = session.log or log;
	if session.conn then
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
		session.conn.close();
		component_listener.disconnect(session.conn, "stream error");
	end
end

--- Component connlistener
function component_listener.listener(conn, data)
	local session = sessions[conn];
	if not session then
		local _send = conn.write;
		session = { type = "component", conn = conn, send = function (data) return _send(tostring(data)); end };
		sessions[conn] = session;

		-- Logging functions --
		
		local conn_name = "xep114-"..tostring(conn):match("[a-f0-9]+$");
		session.log = logger.init(conn_name);
		session.close = session_close;
		
		session.log("info", "Incoming XEP-0114 connection");
		
		local parser = lxp.new(init_xmlhandlers(session, stream_callbacks), "|");
		session.parser = parser;
		
		session.notopen = true;
		
		function session.data(conn, data)
			local ok, err = parser:parse(data);
			if ok then return; end
			session:close("xml-not-well-formed");
		end
		
		session.dispatch_stanza = stream_callbacks.handlestanza;
		
	end
	if data then
		session.data(conn, data);
	end
end
	
function component_listener.disconnect(conn, err)
	local session = sessions[conn];
	if session then
		(session.log or log)("info", "component disconnected: %s (%s)", tostring(session.host), tostring(err));
		if session.host then
			if session.component then
				deregister_component(session.host);
			end
		end
		sessions[conn]  = nil;
		session = nil;
		collectgarbage("collect");
	end
end

connlisteners.register('component', component_listener);

module:add_event_hook("server-starting", function () connlisteners.start("component"); end);
