
local pposix = assert(require "util.pposix");

local config_get = require "core.configmanager".get;
local logger_set = require "util.logger".setwriter;

module.host = "*"; -- we're a global module

if not config_get("*", "core", "no_daemonize") then
	local function daemonize_server()
		local logwriter;
		
		local logfilename = config_get("*", "core", "log");
		if logfilename then
			local logfile = io.open(logfilename, "a+");
			if logfile then
				local write, format, flush = logfile.write, string.format, logfile.flush;
				logwriter = function (name, level, message, ...)
							if ... then 
								write(logfile, name, "\t", level, "\t", format(message, ...), "\n");
							else
								write(logfile, name, "\t" , level, "\t", message, "\n");
							end
							flush(logfile);
						end;
			end
		else
			log("debug", "No logging specified, will continue with default");
		end
		
		local ok, ret = pposix.daemonize();
		if not ok then
			log("error", "Failed to daemonize: %s", ret);
		elseif ret and ret > 0 then
			log("info", "Daemonized to pid %d", ret);			
			os.exit(0);
		else
			if logwriter then
				local ok, ret = logger_set(logwriter);
				if not ok then
					log("error", "Couldn't set new log output: %s", ret);
				end
			end
			log("info", "Successfully daemonized");	
		end
	end
	module:add_event_hook("server-starting", daemonize_server);
end
