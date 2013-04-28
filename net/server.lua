-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local use_luaevent = prosody and require "core.configmanager".get("*", "use_libevent");

if use_luaevent then
	use_luaevent = pcall(require, "luaevent.core");
	if not use_luaevent then
		log("error", "libevent not found, falling back to select()");
	end
end

local server;

if use_luaevent then
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
else
	use_luaevent = false;
	server = require "net.server_select";
end

if prosody then
	local config_get = require "core.configmanager".get;
	local defaults = {};
	for k,v in pairs(server.cfg or server.getsettings()) do
		defaults[k] = v;
	end
	local function load_config()
		local settings = config_get("*", "network_settings") or {};
		if use_luaevent then
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
		else
			local select_settings = {};
			for k,default in pairs(defaults) do
				select_settings[k] = settings[k] or default;
			end
			server.changesettings(select_settings);
		end
	end
	load_config();
	prosody.events.add_handler("config-reloaded", load_config);
end

-- require "net.server" shall now forever return this,
-- ie. server_select or server_event as chosen above.
return server;
