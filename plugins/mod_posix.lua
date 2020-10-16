-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local want_pposix_version = "0.4.0";

local pposix = assert(require "util.pposix");
if pposix._VERSION ~= want_pposix_version then
	module:log("warn", "Unknown version (%s) of binary pposix module, expected %s."
		.. "Perhaps you need to recompile?", tostring(pposix._VERSION), want_pposix_version);
end

local have_signal, signal = pcall(require, "util.signal");
if not have_signal then
	module:log("warn", "Couldn't load signal library, won't respond to SIGTERM");
end

local lfs = require "lfs";
local stat = lfs.attributes;

local prosody = _G.prosody;

module:set_global(); -- we're a global module

local umask = module:get_option_string("umask", "027");
pposix.umask(umask);

-- Don't even think about it!
if not prosody.start_time then -- server-starting
	if pposix.getuid() == 0 and not module:get_option_boolean("run_as_root") then
		module:log("error", "Danger, Will Robinson! Prosody doesn't need to be run as root, so don't do it!");
		module:log("error", "For more information on running Prosody as root, see https://prosody.im/doc/root");
		prosody.shutdown("Refusing to run as root");
	end
end

local pidfile;
local pidfile_handle;

local function remove_pidfile()
	if pidfile_handle then
		pidfile_handle:close();
		os.remove(pidfile);
		pidfile, pidfile_handle = nil, nil;
	end
end

local function write_pidfile()
	if pidfile_handle then
		remove_pidfile();
	end
	pidfile = module:get_option_path("pidfile", nil, "data");
	if pidfile then
		local err;
		local mode = stat(pidfile) and "r+" or "w+";
		pidfile_handle, err = io.open(pidfile, mode);
		if not pidfile_handle then
			module:log("error", "Couldn't write pidfile at %s; %s", pidfile, err);
			prosody.shutdown("Couldn't write pidfile");
		else
			if not lfs.lock(pidfile_handle, "w") then -- Exclusive lock
				local other_pid = pidfile_handle:read("*a");
				module:log("error", "Another Prosody instance seems to be running with PID %s, quitting", other_pid);
				pidfile_handle = nil;
				prosody.shutdown("Prosody already running");
			else
				pidfile_handle:close();
				pidfile_handle, err = io.open(pidfile, "w+");
				if not pidfile_handle then
					module:log("error", "Couldn't write pidfile at %s; %s", pidfile, err);
					prosody.shutdown("Couldn't write pidfile");
				else
					if lfs.lock(pidfile_handle, "w") then
						pidfile_handle:write(tostring(pposix.getpid()));
						pidfile_handle:flush();
					end
				end
			end
		end
	end
end

local daemonize = prosody.opts.daemonize;

if daemonize == nil then
	-- Fall back to config file if not specified on command-line
	daemonize = module:get_option_boolean("daemonize", nil);
	if daemonize ~= nil then
		module:log("warn", "The 'daemonize' option has been deprecated, specify -D or -F on the command line instead.");
		-- TODO: Write some docs and include a link in the warning.
	end
end

local function remove_log_sinks()
	local lm = require "core.loggingmanager";
	lm.register_sink_type("console", nil);
	lm.register_sink_type("stdout", nil);
	lm.reload_logging();
end

if daemonize then
	local function daemonize_server()
		module:log("info", "Prosody is about to detach from the console, disabling further console output");
		remove_log_sinks();
		local ok, ret = pposix.daemonize();
		if not ok then
			module:log("error", "Failed to daemonize: %s", ret);
		elseif ret and ret > 0 then
			os.exit(0);
		else
			module:log("info", "Successfully daemonized to PID %d", pposix.getpid());
			write_pidfile();
		end
	end
	module:hook("server-started", daemonize_server)
else
	-- Not going to daemonize, so write the pid of this process
	write_pidfile();
end

module:hook("server-stopped", remove_pidfile);

-- Set signal handlers
if have_signal then
	module:add_timer(0, function ()
		signal.signal("SIGTERM", function ()
			module:log("warn", "Received SIGTERM");
			prosody.unlock_globals();
			prosody.shutdown("Received SIGTERM");
			prosody.lock_globals();
		end);

		signal.signal("SIGHUP", function ()
			module:log("info", "Received SIGHUP");
			prosody.reload_config();
			-- this also reloads logging
		end);

		signal.signal("SIGINT", function ()
			module:log("info", "Received SIGINT");
			prosody.unlock_globals();
			prosody.shutdown("Received SIGINT");
			prosody.lock_globals();
		end);

		signal.signal("SIGUSR1", function ()
			module:log("info", "Received SIGUSR1");
			module:fire_event("signal/SIGUSR1");
		end);

		signal.signal("SIGUSR2", function ()
			module:log("info", "Received SIGUSR2");
			module:fire_event("signal/SIGUSR2");
		end);
	end);
end

-- For other modules to reference
features = {
	signal_events = true;
};
