-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

if not (prosody and prosody.config_loaded) then
	-- This module only supports loading inside Prosody, outside Prosody
	-- you should directly require net.server_select or server_event, etc.
	error(debug.traceback("Loading outside Prosody or Prosody not yet initialized"), 0);
end

local log = require "prosody.util.logger".init("net.server");

local default_backend = "epoll";

local server_type = require "prosody.core.configmanager".get("*", "network_backend") or default_backend;

if require "prosody.core.configmanager".get("*", "use_libevent") then
	server_type = "event";
end

if server_type == "event" then
	if not pcall(require, "luaevent.core") then
		log("error", "libevent not found, falling back to %s", default_backend);
		server_type = default_backend;
	end
end

local server;
local set_config;
if server_type == "event" then
	server = require "prosody.net.server_event";

	local defaults = {};
	for k,v in pairs(server.cfg) do
		defaults[k] = v;
	end
	function set_config(settings)
		local event_settings = {
			ACCEPT_DELAY = settings.accept_retry_interval;
			ACCEPT_QUEUE = settings.tcp_backlog;
			CLEAR_DELAY = settings.event_clear_interval;
			CONNECT_TIMEOUT = settings.connect_timeout;
			DEBUG = settings.debug;
			HANDSHAKE_TIMEOUT = settings.ssl_handshake_timeout;
			MAX_CONNECTIONS = settings.max_connections;
			MAX_HANDSHAKE_ATTEMPTS = settings.max_ssl_handshake_roundtrips;
			MAX_READ_LENGTH = settings.max_receive_buffer_size;
			MAX_SEND_LENGTH = settings.max_send_buffer_size;
			READ_TIMEOUT = settings.read_timeout;
			WRITE_TIMEOUT = settings.send_timeout;
		};

		for k,default in pairs(defaults) do
			server.cfg[k] = event_settings[k] or default;
		end
	end
elseif server_type == "select" then
	-- TODO Remove completely.
	log("warn", "select is deprecated, the new default is epoll. For more info see https://prosody.im/doc/network_backend");
	server = require "prosody.net.server_select";

	local defaults = {};
	for k,v in pairs(server.getsettings()) do
		defaults[k] = v;
	end
	function set_config(settings)
		local select_settings = {};
		for k,default in pairs(defaults) do
			select_settings[k] = settings[k] or default;
		end
		server.changesettings(select_settings);
	end
else
	server = require("prosody.net.server_"..server_type);
	set_config = server.set_config;
	if not server.get_backend then
		function server.get_backend()
			return server_type;
		end
	end
end

-- If server.hook_signal exists, replace signal.signal()
local has_signal, signal = pcall(require, "prosody.util.signal");
if has_signal then
	if server.hook_signal then
		function signal.signal(signal_id, handler)
			if type(signal_id) == "string" then
				signal_id = signal[signal_id:upper()];
			end
			if type(signal_id) ~= "number" then
				return false, "invalid-signal";
			end
			return server.hook_signal(signal_id, handler);
		end
	else
		server.hook_signal = signal.signal;
	end
else
	if not server.hook_signal then
		server.hook_signal = function()
			return false, "signal hooking not supported"
		end
	end
end

if prosody and set_config then
	local config_get = require "prosody.core.configmanager".get;
	local function load_config()
		local settings = config_get("*", "network_settings") or {};
		return set_config(settings);
	end
	load_config();
	prosody.events.add_handler("config-reloaded", load_config);
end

local tls_builder = server.tls_builder;
-- resolving the basedir here avoids util.sslconfig depending on
-- prosody.paths.config
function server.tls_builder()
	return tls_builder(prosody.paths.config or "")
end

-- require "prosody.net.server" shall now forever return this,
-- ie. server_select or server_event as chosen above.
return server;
