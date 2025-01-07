module:set_global();

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
if not have_unix or type(unix) ~= "table" then
	module:log_status("error", "LuaSocket unix socket support not available or incompatible, ensure it is up to date");
	return;
end

local server = require "prosody.net.server";

local adminstream = require "prosody.util.adminstream";
local st = require "prosody.util.stanza";

local socket_path = module:get_option_path("admin_socket", "prosody.sock", "data");

local sessions = module:shared("sessions");

local function fire_admin_event(session, stanza)
	local event_data = {
		origin = session, stanza = stanza;
	};
	local event_name;
	if stanza.attr.xmlns then
		event_name = "admin/"..stanza.attr.xmlns..":"..stanza.name;
	else
		event_name = "admin/"..stanza.name;
	end
	module:log("debug", "Firing %s", event_name);
	local ret = module:fire_event(event_name, event_data);
	if ret == nil then
		session.send(st.stanza("repl-result", { type = "error" }):text("No module handled this query. Is mod_admin_shell enabled?"));
	end
	return ret;
end

module:hook("server-stopping", function ()
	for _, session in pairs(sessions) do
		session:close("system-shutdown");
	end
	os.remove(socket_path);
end);

--- Unix domain socket management

local conn, sock;

local admin_server = adminstream.server(sessions, fire_admin_event);
local listeners = admin_server.listeners;

module:hook_object_event(admin_server.events, "disconnected", function (event)
	return module:fire_event("admin-disconnected", event);
end);

local function accept_connection()
	module:log("debug", "accepting...");
	local client = sock:accept();
	if not client then return; end
	server.wrapclient(client, "unix", 0, listeners, "*a");
end

function module.load()
	sock = unix.stream();
	sock:settimeout(0);
	os.remove(socket_path);
	local ok, err = sock:bind(socket_path);
	if not ok then
		module:log_status("error", "Unable to bind admin socket %s: %s", socket_path, err);
		return;
	end
	local ok, err = sock:listen();
	if not ok then
		module:log_status("error", "Unable to listen on admin socket %s: %s", socket_path, err);
		return;
	end
	if server.wrapserver then
		conn = server.wrapserver(sock, socket_path, 0, listeners);
	else
		conn = server.watchfd(sock:getfd(), accept_connection);
	end
end

function module.unload()
	if conn then
		conn:close();
	end
	if sock then
		sock:close();
	end
	os.remove(socket_path);
end
