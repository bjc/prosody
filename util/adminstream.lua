local st = require "prosody.util.stanza";
local new_xmpp_stream = require "prosody.util.xmppstream".new;
local sessionlib = require "prosody.util.session";
local gettime = require "prosody.util.time".now;
local runner = require "prosody.util.async".runner;
local add_task = require "prosody.util.timer".add_task;
local events = require "prosody.util.events";
local server = require "prosody.net.server";

local stream_close_timeout = 5;

local log = require "prosody.util.logger".init("adminstream");

local xmlns_xmpp_streams = "urn:ietf:params:xml:ns:xmpp-streams";

local stream_callbacks = { default_ns = "xmpp:prosody.im/admin" };

function stream_callbacks.streamopened(session, attr)
	-- run _streamopened in async context
	session.thread:run({ stream = "opened", attr = attr });
end

function stream_callbacks._streamopened(session, attr) --luacheck: ignore 212/attr
	if session.type ~= "client" then
		session:open_stream();
	end
	session.notopen = nil;
end

function stream_callbacks.streamclosed(session, attr)
	-- run _streamclosed in async context
	session.thread:run({ stream = "closed", attr = attr });
end

function stream_callbacks._streamclosed(session)
	session.log("debug", "Received </stream:stream>");
	session:close(false);
end

function stream_callbacks.error(session, error, data)
	if error == "no-stream" then
		session.log("debug", "Invalid opening stream header (%s)", (data:gsub("^([^\1]+)\1", "{%1}")));
		session:close("invalid-namespace");
	elseif error == "parse-error" then
		session.log("debug", "Client XML parse error: %s", data);
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

function stream_callbacks.handlestanza(session, stanza)
	session.thread:run(stanza);
end

local runner_callbacks = {};

function runner_callbacks:error(err)
	self.data.log("error", "Traceback[c2s]: %s", err);
end

local stream_xmlns_attr = {xmlns='urn:ietf:params:xml:ns:xmpp-streams'};

local function destroy_session(session, reason)
	if session.destroyed then return; end
	session.destroyed = true;
	session.log("debug", "Destroying session: %s", reason or "unknown reason");
end

local function session_close(session, reason)
	local log = session.log or log;
	local conn = session.conn;
	if conn then
		if session.notopen then
			session:open_stream();
		end
		if reason then -- nil == no err, initiated by us, false == initiated by client
			local stream_error = st.stanza("stream:error");
			if type(reason) == "string" then -- assume stream error
				stream_error:tag(reason, {xmlns = 'urn:ietf:params:xml:ns:xmpp-streams' });
			elseif type(reason) == "table" then
				if reason.condition then
					stream_error:tag(reason.condition, stream_xmlns_attr):up();
					if reason.text then
						stream_error:tag("text", stream_xmlns_attr):text(reason.text):up();
					end
					if reason.extra then
						stream_error:add_child(reason.extra);
					end
				elseif reason.name then -- a stanza
					stream_error = reason;
				end
			end
			stream_error = tostring(stream_error);
			log("debug", "Disconnecting client, <stream:error> is: %s", stream_error);
			session.send(stream_error);
		end

		session.send("</stream:stream>");
		function session.send() return false; end

		local reason_text = (reason and (reason.name or reason.text or reason.condition)) or reason;
		session.log("debug", "c2s stream for %s closed: %s", session.full_jid or session.ip or "<unknown>", reason_text or "session closed");

		-- Authenticated incoming stream may still be sending us stanzas, so wait for </stream:stream> from remote
		if reason_text == nil and not session.notopen and session.type == "c2s" then
			-- Grace time to process data from authenticated cleanly-closed stream
			add_task(stream_close_timeout, function ()
				if not session.destroyed then
					session.log("warn", "Failed to receive a stream close response, closing connection anyway...");
					destroy_session(session);
					conn:close();
				end
			end);
		else
			destroy_session(session, reason_text);
			conn:close();
		end
	else
		local reason_text = (reason and (reason.name or reason.text or reason.condition)) or reason;
		destroy_session(session, reason_text);
	end
end

--- Public methods

local function new_connection(socket_path, listeners)
	local have_unix, unix = pcall(require, "socket.unix");
	if have_unix and type(unix) == "function" then
		-- COMPAT #1717
		-- Before the introduction of datagram support, only the stream socket
		-- constructor was exported instead of a module table. Due to the lack of a
		-- proper release of LuaSocket, distros have settled on shipping either the
		-- last RC tag or some commit since then.
		-- Here we accommodate both variants.
		unix = { stream = unix };
	end
	if type(unix) ~= "table" then
		have_unix = false;
	end
	local conn, sock;

	return {
		connect = function ()
			if not have_unix then
				return nil, "no unix socket support";
			end
			if sock or conn then
				return nil, "already connected";
			end
			sock = unix.stream();
			sock:settimeout(0);
			local ok, err = sock:connect(socket_path);
			if not ok then
				return nil, err;
			end
			conn = server.wrapclient(sock, nil, nil, listeners, "*a");
			return true;
		end;
		disconnect = function ()
			if conn then
				conn:close();
				conn = nil;
			end
			if sock then
				sock:close();
				sock = nil;
			end
			return true;
		end;
	};
end

local function new_server(sessions, stanza_handler)
	local s = {
		events = events.new();
		listeners = {};
	};

	function s.listeners.onconnect(conn)
		log("debug", "New connection");
		local session = sessionlib.new("admin");
		sessionlib.set_id(session);
		sessionlib.set_logger(session);
		sessionlib.set_conn(session, conn);

		session.conntime = gettime();
		session.type = "admin";

		local stream = new_xmpp_stream(session, stream_callbacks);
		session.stream = stream;
		session.notopen = true;

		session.thread = runner(function (stanza)
			if st.is_stanza(stanza) then
				stanza_handler(session, stanza);
			elseif stanza.stream == "opened" then
				stream_callbacks._streamopened(session, stanza.attr);
			elseif stanza.stream == "closed" then
				stream_callbacks._streamclosed(session, stanza.attr);
			end
		end, runner_callbacks, session);

		function session.data(data)
			-- Parse the data, which will store stanzas in session.pending_stanzas
			if data then
				local ok, err = stream:feed(data);
				if not ok then
					session.log("debug", "Received invalid XML (%s) %d bytes: %q", err, #data, data:sub(1, 300));
					session:close("not-well-formed");
				end
			end
		end

		session.close = session_close;

		session.send = function (t)
			session.log("debug", "Sending[%s]: %s", session.type, t.top_tag and t:top_tag() or t:match("^[^>]*>?"));
			return session.rawsend(tostring(t));
		end

		function session.rawsend(t)
			local ret, err = conn:write(t);
			if not ret then
				session.log("debug", "Error writing to connection: %s", err);
				return false, err;
			end
			return true;
		end

		sessions[conn] = session;
	end

	function s.listeners.onincoming(conn, data)
		local session = sessions[conn];
		if session then
			session.data(data);
		end
	end

	function s.listeners.ondisconnect(conn, err)
		local session = sessions[conn];
		if session then
			session.log("info", "Admin client disconnected: %s", err or "connection closed");
			session.conn = nil;
			sessions[conn]  = nil;
			s.events.fire_event("disconnected", { session = session });
		end
	end

	function s.listeners.onreadtimeout(conn)
		return conn:send(" ");
	end

	return s;
end

local function new_client()
	local client = {
		type = "client";
		events = events.new();
		log = log;
	};

	local listeners = {};

	function listeners.onconnect(conn)
		log("debug", "Connected");
		client.conn = conn;

		local stream = new_xmpp_stream(client, stream_callbacks);
		client.stream = stream;
		client.notopen = true;

		client.thread = runner(function (stanza)
			if st.is_stanza(stanza) then
				if not client.events.fire_event("received", stanza) and not stanza.attr.xmlns then
					client.events.fire_event("received/"..stanza.name, stanza);
				end
			elseif stanza.stream == "opened" then
				stream_callbacks._streamopened(client, stanza.attr);
				client.events.fire_event("connected");
			elseif stanza.stream == "closed" then
				client.events.fire_event("disconnected");
				stream_callbacks._streamclosed(client, stanza.attr);
			end
		end, runner_callbacks, client);

		client.close = session_close;

		function client.send(t)
			client.log("debug", "Sending: %s", t.top_tag and t:top_tag() or t:match("^[^>]*>?"));
			return client.rawsend(tostring(t));
		end

		function client.rawsend(t)
			local ret, err = conn:write(t);
			if not ret then
				client.log("debug", "Error writing to connection: %s", err);
				return false, err;
			end
			return true;
		end
		client.log("debug", "Opening stream...");
		client:open_stream();
	end

	function listeners.onincoming(conn, data) --luacheck: ignore 212/conn
		local ok, err = client.stream:feed(data);
		if not ok then
			client.log("debug", "Received invalid XML (%s) %d bytes: %q", err, #data, data:sub(1, 300));
			client:close("not-well-formed");
		end
	end

	function listeners.ondisconnect(conn, err) --luacheck: ignore 212/conn
		client.log("info", "Admin client disconnected: %s", err or "connection closed");
		client.conn = nil;
		client.events.fire_event("disconnected");
	end

	function listeners.onreadtimeout(conn)
		conn:send(" ");
	end

	client.listeners = listeners;

	return client;
end

return {
	connection = new_connection;
	server = new_server;
	client = new_client;
};
