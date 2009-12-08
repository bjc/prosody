-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local want_pposix_version = "0.3.1";

local pposix = assert(require "util.pposix");
if pposix._VERSION ~= want_pposix_version then module:log("warn", "Unknown version (%s) of binary pposix module, expected %s", tostring(pposix._VERSION), want_pposix_version); end

local signal = select(2, pcall(require, "util.signal"));
if type(signal) == "string" then
	module:log("warn", "Couldn't load signal library, won't respond to SIGTERM");
end

local logger_set = require "util.logger".setwriter;

local prosody = _G.prosody;

module.host = "*"; -- we're a global module

-- Allow switching away from root, some people like strange ports.
module:add_event_hook("server-started", function ()
		local uid = module:get_option("setuid");
		local gid = module:get_option("setgid");
		if gid then
			local success, msg = pposix.setgid(gid);
			if success then
				module:log("debug", "Changed group to "..gid.." successfully.");
			else
				module:log("error", "Failed to change group to "..gid..". Error: "..msg);
				prosody.shutdown("Failed to change group to "..gid);
			end
		end
		if uid then
			local success, msg = pposix.setuid(uid);
			if success then
				module:log("debug", "Changed user to "..uid.." successfully.");
			else
				module:log("error", "Failed to change user to "..uid..". Error: "..msg);
				prosody.shutdown("Failed to change user to "..uid);
			end
		end
	end);

-- Don't even think about it!
module:add_event_hook("server-starting", function ()
		local suid = module:get_option("setuid");
		if not suid or suid == 0 or suid == "root" then
			if pposix.getuid() == 0 and not module:get_option("run_as_root") then
				module:log("error", "Danger, Will Robinson! Prosody doesn't need to be run as root, so don't do it!");
				module:log("error", "For more information on running Prosody as root, see http://prosody.im/doc/root");
				prosody.shutdown("Refusing to run as root");
			end
		end
	end);

local pidfile_written;

local function remove_pidfile()
	if pidfile_written then
		os.remove(pidfile_written);
		pidfile_written = nil;
	end
end

local function write_pidfile()
	if pidfile_written then
		remove_pidfile();
	end
	local pidfile = module:get_option("pidfile");
	if pidfile then
		local pf, err = io.open(pidfile, "w+");
		if not pf then
			module:log("error", "Couldn't write pidfile; %s", err);
		else
			pf:write(tostring(pposix.getpid()));
			pf:close();
			pidfile_written = pidfile;
		end
	end
end

local syslog_opened 
function syslog_sink_maker(config)
	if not syslog_opened then
		pposix.syslog_open("prosody");
		syslog_opened = true;
	end
	local syslog, format = pposix.syslog_log, string.format;
	return function (name, level, message, ...)
			if ... then
				syslog(level, format(message, ...));
			else
				syslog(level, message);
			end
		end;
end
require "core.loggingmanager".register_sink_type("syslog", syslog_sink_maker);

local daemonize = module:get_option("daemonize");
if daemonize == nil then
	local no_daemonize = module:get_option("no_daemonize"); --COMPAT w/ 0.5
	daemonize = not no_daemonize;
	if no_daemonize ~= nil then
		module:log("warn", "The 'no_daemonize' option is now replaced by 'daemonize'");
		module:log("warn", "Update your config from 'no_daemonize = %s' to 'daemonize = %s'", tostring(no_daemonize), tostring(daemonize));
	end
end

if daemonize then
	local function daemonize_server()
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
	module:add_event_hook("server-starting", daemonize_server);
else
	-- Not going to daemonize, so write the pid of this process
	write_pidfile();
end

module:add_event_hook("server-stopped", remove_pidfile);

-- Set signal handlers
if signal.signal then
	signal.signal("SIGTERM", function ()
		module:log("warn", "Received SIGTERM");
		signal.signal("SIGTERM", function () end); -- Fixes us getting into some kind of loop
		prosody.unlock_globals();
		prosody.shutdown("Received SIGTERM");
		prosody.lock_globals();
	end);

	signal.signal("SIGHUP", function ()
		module:log("info", "Received SIGHUP");
		prosody.reload_config();
		prosody.reopen_logfiles();
	end);
	
	signal.signal("SIGINT", function ()
		module:log("info", "Received SIGINT");
		signal.signal("SIGINT", function () end); -- Fix to not loop
		prosody.unlock_globals();
		prosody.shutdown("Received SIGINT");
		prosody.lock_globals();
	end);
end
