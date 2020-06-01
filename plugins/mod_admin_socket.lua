module:set_global();

local have_unix, unix = pcall(require, "socket.unix");

if not have_unix or type(unix) ~= "table" then
	module:log_status("error", "LuaSocket unix socket support not available or incompatible, ensure it is up to date");
	return;
end

local server = require "net.server";

local adminstream = require "util.adminstream";

local socket_path = module:get_option_string("admin_socket", prosody.paths.data.."/prosody.sock");

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
	return module:fire_event(event_name, event_data);
end

module:hook("server-stopping", function ()
	for _, session in pairs(sessions) do
		session:close("system-shutdown");
	end
	os.remove(socket_path);
end);

--- Unix domain socket management

local conn, sock;

local listeners = adminstream.server(sessions, fire_admin_event).listeners;

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
	assert(sock:bind(socket_path));
	assert(sock:listen());
	conn = server.watchfd(sock:getfd(), accept_connection);
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
