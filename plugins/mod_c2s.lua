-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:set_global();

local add_task = require "util.timer".add_task;
local new_xmpp_stream = require "util.xmppstream".new;
local nameprep = require "util.encodings".stringprep.nameprep;
local sessionmanager = require "core.sessionmanager";
local st = require "util.stanza";
local sm_new_session, sm_destroy_session = sessionmanager.new_session, sessionmanager.destroy_session;
local uuid_generate = require "util.uuid".generate;

local xpcall, tostring, type = xpcall, tostring, type;
local traceback = debug.traceback;

local xmlns_xmpp_streams = "urn:ietf:params:xml:ns:xmpp-streams";

local log = module._log;

local c2s_timeout = module:get_option_number("c2s_timeout");
local opt_keepalives = module:get_option_boolean("tcp_keepalives", false);

local sessions = module:shared("sessions");

local stream_callbacks = { default_ns = "jabber:client", handlestanza = core_process_stanza };
local listener = {};

--- Stream events handlers
local stream_xmlns_attr = {xmlns='urn:ietf:params:xml:ns:xmpp-streams'};
local default_stream_attr = { ["xmlns:stream"] = "http://etherx.jabber.org/streams", xmlns = stream_callbacks.default_ns, version = "1.0", id = "" };

function stream_callbacks.streamopened(session, attr)
	local send = session.send;
	session.host = nameprep(attr.to);
	if not session.host then
		session:close{ condition = "improper-addressing",
			text = "A valid 'to' attribute is required on stream headers" };
		return;
	end
	session.version = tonumber(attr.version) or 0;
	session.streamid = uuid_generate();
	(session.log or session)("debug", "Client sent opening <stream:stream> to %s", session.host);

	if not hosts[session.host] then
		-- We don't serve this host...
		session:close{ condition = "host-unknown", text = "This server does not serve "..tostring(session.host)};
		return;
	end

	send("<?xml version='1.0'?>"..st.stanza("stream:stream", {
		xmlns = 'jabber:client', ["xmlns:stream"] = 'http://etherx.jabber.org/streams';
		id = session.streamid, from = session.host, version = '1.0', ["xml:lang"] = 'en' }):top_tag());

	(session.log or log)("debug", "Sent reply <stream:stream> to client");
	session.notopen = nil;

	-- If session.secure is *false* (not nil) then it means we /were/ encrypting
	-- since we now have a new stream header, session is secured
	if session.secure == false then
		session.secure = true;
	end

	local features = st.stanza("stream:features");
	hosts[session.host].events.fire_event("stream-features", { origin = session, features = features });
	module:fire_event("stream-features", session, features);

	send(features);
end

function stream_callbacks.streamclosed(session)
	session.log("debug", "Received </stream:stream>");
	session:close();
end

function stream_callbacks.error(session, error, data)
	if error == "no-stream" then
		session.log("debug", "Invalid opening stream header");
		session:close("invalid-namespace");
	elseif error == "parse-error" then
		(session.log or log)("debug", "Client XML parse error: %s", tostring(data));
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

local function handleerr(err) log("error", "Traceback[c2s]: %s: %s", tostring(err), traceback()); end
function stream_callbacks.handlestanza(session, stanza)
	stanza = session.filter("stanzas/in", stanza);
	if stanza then
		return xpcall(function () return core_process_stanza(session, stanza) end, handleerr);
	end
end

--- Session methods
local function session_close(session, reason)
	local log = session.log or log;
	if session.conn then
		if session.notopen then
			session.send("<?xml version='1.0'?>");
			session.send(st.stanza("stream:stream", default_stream_attr):top_tag());
		end
		if reason then
			if type(reason) == "string" then -- assume stream error
				log("info", "Disconnecting client, <stream:error> is: %s", reason);
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
					log("info", "Disconnecting client, <stream:error> is: %s", tostring(stanza));
					session.send(stanza);
				elseif reason.name then -- a stanza
					log("info", "Disconnecting client, <stream:error> is: %s", tostring(reason));
					session.send(reason);
				end
			end
		end
		session.send("</stream:stream>");
		session.conn:close();
		listener.ondisconnect(session.conn, (reason and (reason.text or reason.condition)) or reason or "session closed");
	end
end

--- Port listener
function listener.onconnect(conn)
	local session = sm_new_session(conn);
	sessions[conn] = session;
	
	session.log("info", "Client connected");
	
	-- Client is using legacy SSL (otherwise mod_tls sets this flag)
	if conn:ssl() then
		session.secure = true;
	end
	
	if opt_keepalives then
		conn:setoption("keepalive", opt_keepalives);
	end
	
	session.close = session_close;
	
	local stream = new_xmpp_stream(session, stream_callbacks);
	session.stream = stream;
	session.notopen = true;
	
	function session.reset_stream()
		session.notopen = true;
		session.stream:reset();
	end
	
	local filter = session.filter;
	function session.data(data)
		data = filter("bytes/in", data);
		if data then
			local ok, err = stream:feed(data);
			if ok then return; end
			log("debug", "Received invalid XML (%s) %d bytes: %s", tostring(err), #data, data:sub(1, 300):gsub("[\r\n]+", " "):gsub("[%z\1-\31]", "_"));
			session:close("not-well-formed");
		end
	end

	
	if c2s_timeout then
		add_task(c2s_timeout, function ()
			if session.type == "c2s_unauthed" then
				session:close("connection-timeout");
			end
		end);
	end

	session.dispatch_stanza = stream_callbacks.handlestanza;
end

function listener.onincoming(conn, data)
	local session = sessions[conn];
	if session then
		session.data(data);
	end
end

function listener.ondisconnect(conn, err)
	local session = sessions[conn];
	if session then
		(session.log or log)("info", "Client disconnected: %s", err);
		sm_destroy_session(session, err);
		sessions[conn]  = nil;
		session = nil;
	end
end

function listener.associate_session(conn, session)
	sessions[conn] = session;
end

module:add_item("net-provider", {
	name = "c2s";
	listener = listener;
	default_port = 5222;
	encryption = "starttls";
	multiplex = {
		pattern = "^<.*:stream.*%sxmlns%s*=%s*(['\"])jabber:client%1.*>";
	};
});

module:add_item("net-provider", {
	name = "legacy_ssl";
	listener = listener;
	encryption = "ssl";
	multiplex = {
		pattern = "^<.*:stream.*%sxmlns%s*=%s*(['\"])jabber:client%1.*>";
	};
});


