-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:set_global();

local t_concat = table.concat;
local tostring, type = tostring, type;
local xpcall = require "prosody.util.xpcall".xpcall;
local traceback = debug.traceback;

local logger = require "prosody.util.logger";
local sha1 = require "prosody.util.hashes".sha1;
local st = require "prosody.util.stanza";

local jid_host = require "prosody.util.jid".host;
local new_xmpp_stream = require "prosody.util.xmppstream".new;
local uuid_gen = require "prosody.util.uuid".generate;

local core_process_stanza = prosody.core_process_stanza;
local hosts = prosody.hosts;

local log = module._log;

local opt_keepalives = module:get_option_boolean("component_tcp_keepalives", module:get_option_boolean("tcp_keepalives", true));
local stanza_size_limit = module:get_option_integer("component_stanza_size_limit",
	module:get_option_integer("s2s_stanza_size_limit", 1024 * 512, 10000), 10000);

local sessions = module:shared("sessions");

local function keepalive(event)
	local session = event.session;
	if not session.notopen then
		return event.session.send(' ');
	end
end

function module.add_host(module)
	if module:get_host_type() ~= "component" then
		error("Don't load mod_component manually, it should be for a component, please see https://prosody.im/doc/components", 0);
	end

	local env = module.environment;
	env.connected = false;
	env.session = false;

	local send;

	local function on_destroy(session, err) --luacheck: ignore 212/err
		module:set_status("warn", err and ("Disconnected: "..err) or "Disconnected");
		env.connected = false;
		env.session = false;
		send = nil;
		session.on_destroy = nil;
	end

	-- Handle authentication attempts by component
	local function handle_component_auth(event)
		local session, stanza = event.origin, event.stanza;

		if session.type ~= "component_unauthed" then return; end

		if (not session.host) or #stanza.tags > 0 then
			(session.log or log)("warn", "Invalid component handshake for host: %s", session.host);
			session:close("not-authorized");
			return true;
		end

		local secret = module:get_option_string("component_secret");
		if not secret then
			(session.log or log)("warn", "Component attempted to identify as %s, but component_secret is not set", session.host);
			session:close("not-authorized");
			return true;
		end

		local supplied_token = t_concat(stanza);
		local calculated_token = sha1(session.streamid..secret, true);
		if supplied_token:lower() ~= calculated_token:lower() then
			module:log("info", "Component authentication failed for %s", session.host);
			session:close{ condition = "not-authorized", text = "Given token does not match calculated token" };
			return true;
		end

		if env.connected then
			local policy = module:get_option_enum("component_conflict_resolve", "kick_new", "kick_old");
			if policy == "kick_old" then
				env.session:close{ condition = "conflict", text = "Replaced by a new connection" };
			else -- kick_new
				module:log("error", "Second component attempted to connect, denying connection");
				session:close{ condition = "conflict", text = "Component already connected" };
				return true;
			end
		end

		env.connected = true;
		env.session = session;
		send = session.send;
		session.on_destroy = on_destroy;
		session.component_validate_from = module:get_option_boolean("validate_from_addresses", true);
		session.type = "component";
		module:log("info", "External component successfully authenticated");
		session.send(st.stanza("handshake"));
		module:fire_event("component-authenticated", { session = session });
		module:set_status("info", "Connected");

		return true;
	end
	module:hook("stanza/jabber:component:accept:handshake", handle_component_auth, -1);

	-- Handle stanzas addressed to this component
	local function handle_stanza(event)
		local stanza = event.stanza;
		if send then
			stanza.attr.xmlns = nil;
			send(stanza);
		else
			if stanza.name == "iq" and stanza.attr.type == "get" and stanza.attr.to == module.host then
				local query = stanza.tags[1];
				local node = query.attr.node;
				if query.name == "query" and query.attr.xmlns == "http://jabber.org/protocol/disco#info" and (not node or node == "") then
					local name = module:get_option_string("name");
					if name then
						local reply = st.reply(stanza):tag("query", { xmlns = "http://jabber.org/protocol/disco#info" })
							:tag("identity", { category = "component", type = "generic", name = module:get_option_string("name", "Prosody") }):up()
							:tag("feature", { var = "http://jabber.org/protocol/disco#info" }):up();
						event.origin.send(reply);
						return true;
					end
				end
			end
			module:log("warn", "Component not connected, bouncing error for: %s", stanza:top_tag());
			if stanza.attr.type ~= "error" and stanza.attr.type ~= "result" then
				event.origin.send(st.error_reply(stanza, "wait", "remote-server-timeout", "Component unavailable", module.host)
					:tag("not-connected", { xmlns = "xmpp:prosody.im/protocol/component" }));
			end
		end
		return true;
	end

	module:hook("iq/bare", handle_stanza, -1);
	module:hook("message/bare", handle_stanza, -1);
	module:hook("presence/bare", handle_stanza, -1);
	module:hook("iq/full", handle_stanza, -1);
	module:hook("message/full", handle_stanza, -1);
	module:hook("presence/full", handle_stanza, -1);
	module:hook("iq/host", handle_stanza, -1);
	module:hook("message/host", handle_stanza, -1);
	module:hook("presence/host", handle_stanza, -1);

	module:hook("component-read-timeout", keepalive, -1);
end

module:hook("component-read-timeout", keepalive, -1);

--- Network and stream part ---

local xmlns_component = 'jabber:component:accept';

local listener = {};

--- Callbacks/data for xmppstream to handle streams for us ---

local stream_callbacks = { default_ns = xmlns_component };

local xmlns_xmpp_streams = "urn:ietf:params:xml:ns:xmpp-streams";

function stream_callbacks.error(session, error, data)
	if session.destroyed then return; end
	module:log("warn", "Error processing component stream: %s", error);
	if error == "no-stream" then
		session:close("invalid-namespace");
	elseif error == "parse-error" then
		session.log("warn", "External component %s XML parse error: %s", session.host, data);
		session:close("not-well-formed");
	elseif error == "stream-error" then
		local condition, text = "undefined-condition";
		for child in data:childtags(nil, xmlns_xmpp_streams) do
			if child.name ~= "text" then
				condition = child.name;
			else
				text = child:get_text();
			end
			if condition ~= "undefined-condition" and text then
				break;
			end
		end
		text = condition .. (text and (" ("..text..")") or "");
		session.log("info", "Session closed by remote with error: %s", text);
		session:close(nil, text);
	end
end

function stream_callbacks.streamopened(session, attr)
	if not attr.to then
		session:close{ condition = "improper-addressing", text = "A 'to' attribute is required on stream headers" };
		return;
	end
	if not hosts[attr.to] or not hosts[attr.to].modules.component then
		session:close{ condition = "host-unknown", text = tostring(attr.to).." does not match any configured external components" };
		return;
	end
	session.host = attr.to;
	session.streamid = uuid_gen();
	session.notopen = nil;
	-- Return stream header
	session:open_stream();
end

function stream_callbacks.streamclosed(session)
	session.log("debug", "Received </stream:stream>");
	session:close();
end

local function handleerr(err) log("error", "Traceback[component]: %s", traceback(err, 2)); end
function stream_callbacks.handlestanza(session, stanza)
	-- Namespaces are icky.
	if not stanza.attr.xmlns and stanza.name == "handshake" then
		stanza.attr.xmlns = xmlns_component;
	end
	if not stanza.attr.xmlns or stanza.attr.xmlns == "jabber:client" then
		local from = stanza.attr.from;
		if session.component_validate_from then
			if not from or (jid_host(from) ~= session.host) then
				-- Return error
				session.log("warn", "Component sent stanza with missing or invalid 'from' address");
				session:close{
					condition = "invalid-from";
					text = "Component tried to send from address <"..(from or "< [missing 'from' attribute] >")
						   .."> which is not in domain <"..tostring(session.host)..">";
				};
				return;
			end
		elseif not from then
			stanza.attr.from = session.host;
		end
		if not stanza.attr.to then
			session.log("warn", "Rejecting stanza with no 'to' address");
			if stanza.attr.type ~= "error" and stanza.attr.type ~= "result" then
				session.send(st.error_reply(stanza, "modify", "bad-request", "Components MUST specify a 'to' address on stanzas"));
			end
			return;
		end
	end

	if stanza then
		return xpcall(core_process_stanza, handleerr, session, stanza);
	end
end

--- Closing a component connection
local stream_xmlns_attr = {xmlns='urn:ietf:params:xml:ns:xmpp-streams'};
local default_stream_attr = { ["xmlns:stream"] = "http://etherx.jabber.org/streams", xmlns = stream_callbacks.default_ns, version = "1.0", id = "" };
local function session_close(session, reason)
	if session.destroyed then return; end
	if session.conn then
		if session.notopen then
			session.send("<?xml version='1.0'?>");
			session.send(st.stanza("stream:stream", default_stream_attr):top_tag());
		end
		if reason then
			if type(reason) == "string" then -- assume stream error
				module:log("info", "Disconnecting component, <stream:error> is: %s", reason);
				session.send(st.stanza("stream:error"):tag(reason, {xmlns = 'urn:ietf:params:xml:ns:xmpp-streams' }));
			elseif st.is_stanza(reason) then
				module:log("info", "Disconnecting component, <stream:error> is: %s", reason);
				session.send(reason);
			elseif type(reason) == "table" then
				if reason.condition then
					local stanza = st.stanza("stream:error"):tag(reason.condition, stream_xmlns_attr):up();
					if reason.text then
						stanza:tag("text", stream_xmlns_attr):text(reason.text):up();
					end
					if reason.extra then
						stanza:add_child(reason.extra);
					end
					module:log("info", "Disconnecting component, <stream:error> is: %s", stanza);
					session.send(stanza);
				end
			end
		end
		session.send("</stream:stream>");
		session.conn:close();
		listener.ondisconnect(session.conn, "stream error");
	end
end

--- Component connlistener

function listener.onconnect(conn)
	local _send = conn.write;
	local session = { type = "component_unauthed", conn = conn, send = function (data) return _send(conn, tostring(data)); end };

	-- Logging functions --
	local conn_name = "jcp"..tostring(session):match("[a-f0-9]+$");
	session.log = logger.init(conn_name);
	session.close = session_close;

	if opt_keepalives then
		conn:setoption("keepalive", opt_keepalives);
	end

	session.log("info", "Incoming Jabber component connection");

	local stream = new_xmpp_stream(session, stream_callbacks, stanza_size_limit);
	session.stream = stream;

	session.notopen = true;

	function session.reset_stream()
		session.notopen = true;
		session.stream:reset();
	end

	function session.data(_, data)
		local ok, err = stream:feed(data);
		if ok then return; end
		log("debug", "Received invalid XML (%s) %d bytes: %q", err, #data, data:sub(1, 300));
		session:close("not-well-formed");
	end

	session.dispatch_stanza = stream_callbacks.handlestanza;

	sessions[conn] = session;
end
function listener.onincoming(conn, data)
	local session = sessions[conn];
	session.data(conn, data);
end
function listener.ondisconnect(conn, err)
	local session = sessions[conn];
	if session then
		(session.log or log)("info", "component disconnected: %s (%s)", session.host, err);
		if session.host then
			module:context(session.host):fire_event("component-disconnected", { session = session, reason = err });
		end
		if session.on_destroy then session:on_destroy(err); end
		sessions[conn] = nil;
		for k in pairs(session) do
			if k ~= "log" and k ~= "close" then
				session[k] = nil;
			end
		end
		session.destroyed = true;
	end
end

function listener.ondetach(conn)
	sessions[conn] = nil;
end

function listener.onreadtimeout(conn)
	local session = sessions[conn];
	if session then
		return (hosts[session.host] or prosody).events.fire_event("component-read-timeout", { session = session });
	end
end

module:provides("net", {
	name = "component";
	private = true;
	listener = listener;
	default_port = 5347;
	multiplex = {
		pattern = "^<.*:stream.*%sxmlns%s*=%s*(['\"])jabber:component:accept%1.*>";
	};
});
