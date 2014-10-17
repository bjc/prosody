-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local server_type = prosody and require "core.configmanager".get("*", "server") or "select";
if prosody and require "core.configmanager".get("*", "use_libevent") then
	server_type = "event";
end

if server_type == "event" then
	if not pcall(require, "luaevent.core") then
		print(log)
		log("error", "libevent not found, falling back to select()");
		server_type = "select"
	end
end

local server;
local set_config;
if server_type == "event" then
	server = require "net.server_event";

	-- Overwrite signal.signal() because we need to ask libevent to
	-- handle them instead
	local ok, signal = pcall(require, "util.signal");
	if ok and signal then
		local _signal_signal = signal.signal;
		function signal.signal(signal_id, handler)
			if type(signal_id) == "string" then
				signal_id = signal[signal_id:upper()];
			end
			if type(signal_id) ~= "number" then
				return false, "invalid-signal";
			end
			return server.hook_signal(signal_id, handler);
		end
	end

	local defaults = {};
	for k,v in pairs(server.cfg) do
		defaults[k] = v;
	end
	function set_config(settings)
		local event_settings = {
			ACCEPT_DELAY = settings.event_accept_retry_interval;
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
	server = require "net.server_select";

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
	error("Unsupported server type")
end

if prosody then
	local config_get = require "core.configmanager".get;
	local function load_config()
		local settings = config_get("*", "network_settings") or {};
		return set_config(settings);
	end
	load_config();
	prosody.events.add_handler("config-reloaded", load_config);
end

-- require "net.server" shall now forever return this,
-- ie. server_select or server_event as chosen above.
return server;
