-- Ignore the CFG_* variables
-- luacheck: ignore 113/CFG_CONFIGDIR 113/CFG_SOURCEDIR 113/CFG_DATADIR 113/CFG_PLUGINDIR
local startup = {};

local prosody = { events = require "prosody.util.events".new() };
local logger = require "prosody.util.logger";
local log = logger.init("startup");
local parse_args = require "prosody.util.argparse".parse;

local config = require "prosody.core.configmanager";
local config_warnings;

local dependencies = require "prosody.util.dependencies";

local original_logging_config;

local default_gc_params = {
	mode = "incremental";
	-- Incremental mode defaults
	threshold = 105, speed = 500;
	-- Generational mode defaults
	minor_threshold = 20, major_threshold = 50;
};

local arg_settigs = {
	prosody = {
		short_params = { D = "daemonize"; F = "no-daemonize", h = "help", ["?"] = "help" };
		value_params = { config = true };
	};
	prosodyctl = {
		short_params = { v = "verbose", h = "help", ["?"] = "help" };
		value_params = { config = true };
	};
}

function startup.parse_args(profile)
	local opts, err, where = parse_args(arg, arg_settigs[profile or prosody.process_type] or profile);
	if not opts then
		if err == "param-not-found" then
			print("Unknown command-line option: "..tostring(where));
			if prosody.process_type == "prosody" then
				print("Perhaps you meant to use prosodyctl instead?");
			end
		elseif err == "missing-value" then
			print("Expected a value to follow command-line option: "..where);
		end
		os.exit(1);
	end
	if prosody.process_type == "prosody" then
		if #arg > 0 then
			print("Unrecognized option: "..arg[1]);
			print("(Did you mean 'prosodyctl "..arg[1].."'?)");
			print("");
		end
		if opts.help or #arg > 0 then
			print("prosody [ -D | -F ] [ --config /path/to/prosody.cfg.lua ]");
			print("  -D, --daemonize       Run in the background")
			print("  -F, --no-daemonize    Run in the foreground")
			print("  --config FILE         Specify config file")
			os.exit(0);
		end
	end
	prosody.opts = opts;
end

function startup.read_config()
	local filenames = {};

	local filename;
	if prosody.opts.config then
		table.insert(filenames, prosody.opts.config);
		if CFG_CONFIGDIR then
			table.insert(filenames, CFG_CONFIGDIR.."/"..prosody.opts.config);
		end
	elseif os.getenv("PROSODY_CONFIG") then -- Passed by prosodyctl
			table.insert(filenames, os.getenv("PROSODY_CONFIG"));
	else
		table.insert(filenames, (CFG_CONFIGDIR or ".").."/prosody.cfg.lua");
	end
	for _,_filename in ipairs(filenames) do
		filename = _filename;
		local file = io.open(filename);
		if file then
			file:close();
			prosody.config_file = filename;
			prosody.paths.config = filename:match("^(.*)[\\/][^\\/]*$");
			CFG_CONFIGDIR = prosody.paths.config; -- luacheck: ignore 111
			break;
		end
	end
	prosody.config_file = filename
	local credentials_directory = os.getenv("CREDENTIALS_DIRECTORY");
	if credentials_directory then
		config.set_credentials_directory(credentials_directory);
	elseif prosody.process_type == "prosody" then
		config.set_credential_fallback_mode("error");
	else
		config.set_credential_fallback_mode("warn");
	end
	local ok, level, err = config.load(filename);
	if not ok then
		print("\n");
		print("**************************");
		if level == "parser" then
			print("A problem occurred while reading the config file "..filename);
			print("");
			local err_line, err_message = tostring(err):match("%[string .-%]:(%d*): (.*)");
			if err:match("chunk has too many syntax levels$") then
				print("An Include statement in a config file is including an already-included");
				print("file and causing an infinite loop. An Include statement in a config file is...");
			else
				print("Error"..(err_line and (" on line "..err_line) or "")..": "..(err_message or tostring(err)));
			end
			print("");
		elseif level == "file" then
			print("Prosody was unable to find the configuration file.");
			print("We looked for: "..filename);
			print("A sample config file is included in the Prosody download called prosody.cfg.lua.dist");
			print("Copy or rename it to prosody.cfg.lua and edit as necessary.");
		end
		print("More help on configuring Prosody can be found at https://prosody.im/doc/configure");
		print("Good luck!");
		print("**************************");
		print("");
		os.exit(1);
	elseif err and #err > 0 then
		config_warnings = err;
	end
	prosody.config_loaded = true;
end

function startup.check_dependencies()
	if not dependencies.check_dependencies() then
		os.exit(1);
	end
end

-- luacheck: globals socket server

function startup.load_libraries()
	-- Load socket framework
	-- luacheck: ignore 111/server 111/socket
	require "prosody.util.import"
	socket = require "socket";
	server = require "prosody.net.server"
end

function startup.init_logging()
	-- Initialize logging
	local loggingmanager = require "prosody.core.loggingmanager"
	loggingmanager.reload_logging();
	prosody.events.add_handler("config-reloaded", function ()
		prosody.events.fire_event("reopen-log-files");
	end);
	prosody.events.add_handler("reopen-log-files", function ()
		loggingmanager.reload_logging();
		prosody.events.fire_event("logging-reloaded");
	end);
end

function startup.log_startup_warnings()
	dependencies.log_warnings();
	if config_warnings then
		for _, warning in ipairs(config_warnings) do
			log("warn", "Configuration warning: %s", warning);
		end
	end
end

function startup.sanity_check()
	for host, host_config in pairs(config.getconfig()) do
		if host ~= "*"
		and host_config.enabled ~= false
		and not host_config.component_module then
			return;
		end
	end
	log("error", "No enabled VirtualHost entries found in the config file.");
	log("error", "At least one active host is required for Prosody to function. Exiting...");
	os.exit(1);
end

function startup.sandbox_require()
	-- Replace require() with one that doesn't pollute _G, required
	-- for neat sandboxing of modules
	-- luacheck: ignore 113/getfenv 111/require
	local _realG = _G;
	local _real_require = require;
	local getfenv = getfenv or function (f)
		-- FIXME: This is a hack to replace getfenv() in Lua 5.2
		local name, env = debug.getupvalue(debug.getinfo(f or 1).func, 1);
		if name == "_ENV" then
			return env;
		end
	end
	function require(...) -- luacheck: ignore 121
		local curr_env = getfenv(2);
		local curr_env_mt = getmetatable(curr_env);
		local _realG_mt = getmetatable(_realG);
		if curr_env_mt and curr_env_mt.__index and not curr_env_mt.__newindex and _realG_mt then
			local old_newindex, old_index;
			old_newindex, _realG_mt.__newindex = _realG_mt.__newindex, curr_env;
			old_index, _realG_mt.__index = _realG_mt.__index, function (_G, k) -- luacheck: ignore 212/_G
				return rawget(curr_env, k);
			end;
			local ret = _real_require(...);
			_realG_mt.__newindex = old_newindex;
			_realG_mt.__index = old_index;
			return ret;
		end
		return _real_require(...);
	end
end

function startup.set_function_metatable()
	local mt = {};
	function mt.__index(f, upvalue)
		local i, name, value = 0;
		repeat
			i = i + 1;
			name, value = debug.getupvalue(f, i);
		until name == upvalue or name == nil;
		return value;
	end
	function mt.__newindex(f, upvalue, value)
		local i, name = 0;
		repeat
			i = i + 1;
			name = debug.getupvalue(f, i);
		until name == upvalue or name == nil;
		if name then
			debug.setupvalue(f, i, value);
		end
	end
	function mt.__tostring(f)
		local info = debug.getinfo(f, "Su");
		local n_params = info.nparams or 0;
		for i = 1, n_params do
			info[i] = debug.getlocal(f, i);
		end
		if info.isvararg then
			info[n_params+1] = "...";
		end
		return ("function @%s:%d(%s)"):format(info.short_src:match("[^\\/]*$"), info.linedefined, table.concat(info, ", "));
	end
	debug.setmetatable(function() end, mt);
end

function startup.detect_platform()
	prosody.platform = "unknown";
	if os.getenv("WINDIR") then
		prosody.platform = "windows";
	elseif package.config:sub(1,1) == "/" then
		prosody.platform = "posix";
	end
end

function startup.detect_installed()
	prosody.installed = nil;
	if CFG_SOURCEDIR and (prosody.platform == "windows" or CFG_SOURCEDIR:match("^/")) then
		prosody.installed = true;
	end
end

function startup.init_global_state()
	-- luacheck: ignore 121
	prosody.bare_sessions = {};
	prosody.full_sessions = {};
	prosody.hosts = {};

	-- COMPAT: These globals are deprecated
	-- luacheck: ignore 111/bare_sessions 111/full_sessions 111/hosts
	bare_sessions = prosody.bare_sessions;
	full_sessions = prosody.full_sessions;
	hosts = prosody.hosts;

	prosody.paths = {
		source = CFG_SOURCEDIR;
		config = CFG_CONFIGDIR or ".";
		plugins = CFG_PLUGINDIR or "plugins";
		data = "data";
	};

	prosody.arg = _G.arg;

	_G.log = logger.init("general");
	prosody.log = logger.init("general");

	startup.detect_platform();
	startup.detect_installed();
	_G.prosody = prosody;

	-- COMPAT Lua < 5.3
	if not math.type then
		require "prosody.util.mathcompat"
	end
end

function startup.setup_datadir()
	prosody.paths.data = config.get("*", "data_path") or CFG_DATADIR or "data";
end

function startup.setup_plugindir()
	local custom_plugin_paths = config.get("*", "plugin_paths");
	local path_sep = package.config:sub(3,3);
	if custom_plugin_paths then
		-- path1;path2;path3;defaultpath...
		-- luacheck: ignore 111
		CFG_PLUGINDIR = table.concat(custom_plugin_paths, path_sep)..path_sep..(CFG_PLUGINDIR or "plugins");
		prosody.paths.plugins = CFG_PLUGINDIR;
	end
end

function startup.setup_plugin_install_path()
	local installer_plugin_path = config.get("*", "installer_plugin_path") or "custom_plugins";
	local path_sep = package.config:sub(3,3);
	installer_plugin_path = config.resolve_relative_path(CFG_DATADIR or "data", installer_plugin_path);
	require"prosody.util.paths".complement_lua_path(installer_plugin_path);
	-- luacheck: ignore 111
	CFG_PLUGINDIR = installer_plugin_path..path_sep..(CFG_PLUGINDIR or "plugins");
	prosody.paths.installer = installer_plugin_path;
	prosody.paths.plugins = CFG_PLUGINDIR;
end

function startup.chdir()
	if prosody.installed then
		local lfs = require "lfs";
		-- Ensure paths are absolute, not relative to the working directory which we're about to change
		local cwd = lfs.currentdir();
		prosody.paths.source = config.resolve_relative_path(cwd, prosody.paths.source);
		prosody.paths.config = config.resolve_relative_path(cwd, prosody.paths.config);
		prosody.paths.data = config.resolve_relative_path(cwd, prosody.paths.data);
		-- Change working directory to data path.
		lfs.chdir(prosody.paths.data);
	end
end

function startup.add_global_prosody_functions()
	-- Function to reload the config file
	function prosody.reload_config()
		log("info", "Reloading configuration file");
		prosody.events.fire_event("reloading-config");
		local ok, level, err = config.load(prosody.config_file);
		if not ok then
			if level == "parser" then
				log("error", "There was an error parsing the configuration file: %s", err);
			elseif level == "file" then
				log("error", "Couldn't read the config file when trying to reload: %s", err);
			end
		else
			prosody.events.fire_event("config-reloaded", {
				filename = prosody.config_file,
				config = config.getconfig(),
			});
		end
		return ok, (err and tostring(level)..": "..tostring(err)) or nil;
	end

	-- Function to reopen logfiles
	function prosody.reopen_logfiles()
		log("info", "Re-opening log files");
		prosody.events.fire_event("reopen-log-files");
	end

	-- Function to initiate prosody shutdown
	function prosody.shutdown(reason, code)
		log("info", "Shutting down: %s", reason or "unknown reason");
		prosody.shutdown_reason = reason;
		prosody.shutdown_code = code;
		prosody.events.fire_event("server-stopping", {
			reason = reason;
			code = code;
		});
		prosody.main_thread:run(startup.shutdown);
	end
end

function startup.load_secondary_libraries()
	--- Load and initialise core modules
	require "prosody.util.xmppstream"
	require "prosody.core.stanza_router"
	require "prosody.core.statsmanager".metric("gauge", "prosody_info", "", "Prosody version", { "version" }):with_labels(prosody.version):set(1);
	require "prosody.core.hostmanager"
	require "prosody.core.portmanager"
	require "prosody.core.modulemanager"
	require "prosody.core.usermanager"
	require "prosody.core.rostermanager"
	require "prosody.core.sessionmanager"

	require "prosody.util.array"
	require "prosody.util.datetime"
	require "prosody.util.iterators"
	require "prosody.util.timer"
	require "prosody.util.helpers"

	pcall(require, "prosody.util.signal") -- Not on Windows

	-- Commented to protect us from
	-- the second kind of people
	--[[
	pcall(require, "remdebug.engine");
	if remdebug then remdebug.engine.start() end
	]]

	require "prosody.util.stanza"
	require "prosody.util.jid"

	prosody.features = require "prosody.core.features".available;
end

function startup.init_http_client()
	local http = require "prosody.net.http"
	local config_ssl = config.get("*", "ssl") or {}
	local https_client = config.get("*", "client_https_ssl")
	http.default.options.sslctx = require "prosody.core.certmanager".create_context("client_https port 0", "client",
		{ capath = config_ssl.capath, cafile = config_ssl.cafile, verify = "peer", }, https_client);
	http.default.options.use_dane = config.get("*", "use_dane")
end

function startup.init_promise()
	local promise = require "prosody.util.promise";

	local timer = require "prosody.util.timer";
	promise.set_nexttick(function(f) return timer.add_task(0, f); end);
end

function startup.init_async()
	local async = require "prosody.util.async";

	local timer = require "prosody.util.timer";
	async.set_nexttick(function(f) return timer.add_task(0, f); end);
	async.set_schedule_function(timer.add_task);
end

function startup.instrument()
	local statsmanager = require "prosody.core.statsmanager";
	local timed = require"prosody.util.openmetrics".timed;

	local adns = require "prosody.net.adns";
	if adns.instrument then
		local m = statsmanager.metric("histogram", "prosody_dns", "seconds", "DNS lookups", { "qclass"; "qtype" }, {
				buckets = { 1 / 1024; 1 / 256; 1 / 64; 1 / 16; 1 / 4; 1; 4 };
		});
		adns.instrument(function(qclass, qtype) return timed(m:with_labels(qclass, qtype)); end);
	end
end

function startup.init_data_store()
	require "prosody.core.storagemanager";
end

local running_state = require "prosody.util.fsm".new({
	default_state = "uninitialized";
	transitions = {
		{ name = "begin_startup",   from = "uninitialized",           to = "starting" };
		{ name = "finish_startup",  from = "starting",                to = "running" };
		{ name = "begin_shutdown",  from = { "running", "starting" }, to = "stopping" };
		{ name = "finish_shutdown", from = "stopping",                to = "stopped" };
	};
	handlers = {
		transitioned = function (transition)
			prosody.state = transition.to;
		end;
	};
	state_handlers = {
		starting = function ()
			prosody.log("debug", "Firing server-starting event");
			prosody.events.fire_event("server-starting");
			prosody.start_time = os.time();
		end;
		running = function ()
			prosody.log("debug", "Startup complete, firing server-started");
			prosody.events.fire_event("server-started");
		end;
	};
}):init();

function startup.prepare_to_start()
	log("info", "Prosody is using the %s backend for connection handling", server.get_backend());

	-- Signal to modules that we are ready to start
	prosody.started = require "prosody.util.promise".new(function (resolve)
		if prosody.state == "running" then
			resolve();
		else
			prosody.events.add_handler("server-started", function ()
				resolve();
			end);
		end
	end):catch(function (err)
		prosody.log("error", "Prosody startup error: %s", err);
	end);

	running_state:begin_startup();
end

function startup.init_global_protection()
	-- Catch global accesses
	-- luacheck: ignore 212/t
	local locked_globals_mt = {
		__index = function (t, k) log("warn", "%s", debug.traceback("Attempt to read a non-existent global '"..tostring(k).."'", 2)); end;
		__newindex = function (t, k, v) error("Attempt to set a global: "..tostring(k).." = "..tostring(v), 2); end;
	};

	function prosody.unlock_globals()
		setmetatable(_G, nil);
	end

	function prosody.lock_globals()
		setmetatable(_G, locked_globals_mt);
	end

	-- And lock now...
	prosody.lock_globals();
end

function startup.read_version()
	-- Try to determine version
	local version_file = io.open((CFG_SOURCEDIR or ".").."/prosody.version");
	prosody.version = "unknown";
	if version_file then
		prosody.version = version_file:read("*a"):gsub("%s*$", "");
		version_file:close();
		if #prosody.version == 12 and prosody.version:match("^[a-f0-9]+$") then
			prosody.version = "hg:"..prosody.version;
		end
	else
		local hg = require"prosody.util.mercurial";
		local hgid = hg.check_id(CFG_SOURCEDIR or ".");
		if hgid then prosody.version = "hg:" .. hgid; end
	end
end

function startup.log_greeting()
	log("info", "Hello and welcome to Prosody version %s", prosody.version);
end

function startup.notify_started()
	running_state:finish_startup();
end

-- Override logging config (used by prosodyctl)
function startup.force_console_logging()
	original_logging_config = config.get("*", "log");
	local log_level = os.getenv("PROSODYCTL_LOG_LEVEL");
	if not log_level then
		if prosody.opts.verbose then
			log_level = "debug";
		elseif prosody.opts.quiet then
			log_level = "error";
		elseif prosody.opts.silent then
			config.set("*", "log", {}); -- ssssshush!
			return
		end
	end
	config.set("*", "log", { { levels = { min = log_level or "info" }, to = "console" } });
end

local function check_posix()
	if prosody.platform ~= "posix" then return end

	local want_pposix_version = "0.4.1";
	local have_pposix, pposix = pcall(require, "prosody.util.pposix");

	if pposix._VERSION ~= want_pposix_version then
		print(string.format("Unknown version (%s) of binary pposix module, expected %s",
			tostring(pposix._VERSION), want_pposix_version));
		os.exit(1);
	end
	if have_pposix and pposix then
		return pposix;
	end
end

function startup.switch_user()
	-- Switch away from root and into the prosody user --
	-- NOTE: This function is only used by prosodyctl.
	-- The prosody process is built with the assumption that
	-- it is already started as the appropriate user.

	local pposix = check_posix()
	if pposix then
		prosody.current_uid = pposix.getuid();
		local arg_root = prosody.opts.root;
		if prosody.current_uid == 0 and config.get("*", "run_as_root") ~= true and not arg_root then
			-- We haz root!
			local desired_user = config.get("*", "prosody_user") or "prosody";
			local desired_group = config.get("*", "prosody_group") or desired_user;
			local ok, err = pposix.setgid(desired_group);
			if ok then
				ok, err = pposix.initgroups(desired_user);
			end
			if ok then
				ok, err = pposix.setuid(desired_user);
				if ok then
					-- Yay!
					prosody.switched_user = true;
				end
			end
			if not prosody.switched_user then
				-- Boo!
				print("Warning: Couldn't switch to Prosody user/group '"..tostring(desired_user).."'/'"..tostring(desired_group).."': "..tostring(err));
			elseif prosody.config_file then
				-- Make sure the Prosody user can read the config
				local conf, err, errno = io.open(prosody.config_file); --luacheck: ignore 211/errno
				if conf then
					conf:close();
				else
					print("The config file is not readable by the '"..desired_user.."' user.");
					print("Prosody will not be able to read it.");
					print("Error was "..err);
					os.exit(1);
				end
			end
		end

		-- Set our umask to protect data files
		pposix.umask(config.get("*", "umask") or "027");
		pposix.setenv("HOME", prosody.paths.data);
		pposix.setenv("PROSODY_CONFIG", prosody.config_file);
	else
		print("Error: Unable to load pposix module. Check that Prosody is installed correctly.")
		print("For more help send the below error to us through https://prosody.im/discuss");
		print(tostring(pposix))
		os.exit(1);
	end
end

function startup.check_unwriteable()
	local function test_writeable(filename)
		local f, err = io.open(filename, "a");
		if not f then
			return false, err;
		end
		f:close();
		return true;
	end

	local unwriteable_files = {};
	if type(original_logging_config) == "string" and original_logging_config:sub(1,1) ~= "*" then
		local ok, err = test_writeable(original_logging_config);
		if not ok then
			table.insert(unwriteable_files, err);
		end
	elseif type(original_logging_config) == "table" then
		for _, rule in ipairs(original_logging_config) do
			if rule.filename then
				local ok, err = test_writeable(rule.filename);
				if not ok then
					table.insert(unwriteable_files, err);
				end
			end
		end
	end

	if #unwriteable_files > 0 then
		print("One of more of the Prosody log files are not");
		print("writeable, please correct the errors and try");
		print("starting prosodyctl again.");
		print("");
		for _, err in ipairs(unwriteable_files) do
			print(err);
		end
		print("");
		os.exit(1);
	end
end

function startup.init_gc()
	-- Apply garbage collector settings from the config file
	local gc = require "prosody.util.gc";
	local gc_settings = config.get("*", "gc") or { mode = default_gc_params.mode };

	local ok, err = gc.configure(gc_settings, default_gc_params);
	if not ok then
		log("error", "Failed to apply GC configuration: %s", err);
		return nil, err;
	end
	return true;
end

function startup.init_errors()
	require "prosody.util.error".configure(config.get("*", "error_library") or {});
end

function startup.make_host(hostname)
	return {
		type = "local",
		events = prosody.events,
		modules = {},
		sessions = {},
		users = require "prosody.core.usermanager".new_null_provider(hostname)
	};
end

function startup.make_dummy_hosts()
	-- When running under prosodyctl, we don't want to
	-- fully initialize the server, so we populate prosody.hosts
	-- with just enough things for most code to work correctly
	-- luacheck: ignore 122/hosts
	prosody.core_post_stanza = function () end; -- TODO: mod_router!

	for hostname in pairs(config.getconfig()) do
		prosody.hosts[hostname] = startup.make_host(hostname);
	end
end

function startup.posix_umask()
	if prosody.platform ~= "posix" then return end
	local pposix = require "prosody.util.pposix";
	local umask = config.get("*", "umask") or "027";
	pposix.umask(umask);
end

function startup.check_user()
	local pposix = check_posix();
	if not pposix then return end
	-- Don't even think about it!
	if pposix.getuid() == 0 and not config.get("*", "run_as_root") then
		print("Danger, Will Robinson! Prosody doesn't need to be run as root, so don't do it!");
		print("For more information on running Prosody as root, see https://prosody.im/doc/root");
		os.exit(1); -- Refusing to run as root
	end
end

local function remove_pidfile()
	local pidfile = prosody.pidfile;
	if prosody.pidfile_handle then
		prosody.pidfile_handle:close();
		os.remove(pidfile);
		prosody.pidfile, prosody.pidfile_handle = nil, nil;
	end
end

function startup.write_pidfile()
	local pposix = check_posix();
	if not pposix then return end
	local lfs = require "lfs";
	local stat = lfs.attributes;
	local pidfile = config.get("*", "pidfile") or nil;
	if not pidfile then return end
	pidfile = config.resolve_relative_path(prosody.paths.data, pidfile);
	local mode = stat(pidfile) and "r+" or "w+";
	local pidfile_handle, err = io.open(pidfile, mode);
	if not pidfile_handle then
		log("error", "Couldn't write pidfile at %s; %s", pidfile, err);
		os.exit(1);
	else
		prosody.pidfile = pidfile;
		if not lfs.lock(pidfile_handle, "w") then -- Exclusive lock
			local other_pid = pidfile_handle:read("*a");
			log("error", "Another Prosody instance seems to be running with PID %s, quitting", other_pid);
			prosody.pidfile_handle = nil;
			os.exit(1);
		else
			pidfile_handle:close();
			pidfile_handle, err = io.open(pidfile, "w+");
			if not pidfile_handle then
				log("error", "Couldn't write pidfile at %s; %s", pidfile, err);
				os.exit(1);
			else
				if lfs.lock(pidfile_handle, "w") then
					pidfile_handle:write(tostring(pposix.getpid()));
					pidfile_handle:flush();
					prosody.pidfile_handle = pidfile_handle;
				end
			end
		end
	end
	prosody.events.add_handler("server-stopped", remove_pidfile);
end

local function remove_log_sinks()
	local lm = require "prosody.core.loggingmanager";
	lm.register_sink_type("console", nil);
	lm.register_sink_type("stdout", nil);
	lm.reload_logging();
end

function startup.posix_daemonize()
	if not prosody.opts.daemonize then return end
	local pposix = check_posix();
	log("info", "Prosody is about to detach from the console, disabling further console output");
	remove_log_sinks();
	local ok, ret = pposix.daemonize();
	if not ok then
		log("error", "Failed to daemonize: %s", ret);
	elseif ret and ret > 0 then
		os.exit(0);
	else
		log("info", "Successfully daemonized to PID %d", pposix.getpid());
	end
end

function startup.hook_posix_signals()
	if prosody.platform ~= "posix" then return end
	local have_signal, signal = pcall(require, "prosody.util.signal");
	if not have_signal then
		log("warn", "Couldn't load signal library, won't respond to SIGTERM");
		return
	end
	signal.signal("SIGTERM", function()
		log("warn", "Received SIGTERM");
		prosody.main_thread:run(function()
			prosody.unlock_globals();
			prosody.shutdown("Received SIGTERM");
			prosody.lock_globals();
		end);
	end);

	signal.signal("SIGHUP", function()
		log("info", "Received SIGHUP");
		prosody.main_thread:run(function() prosody.reload_config(); end);
		-- this also reloads logging
	end);

	signal.signal("SIGINT", function()
		log("info", "Received SIGINT");
		prosody.main_thread:run(function()
			prosody.unlock_globals();
			prosody.shutdown("Received SIGINT");
			prosody.lock_globals();
		end);
	end);

	signal.signal("SIGUSR1", function()
		log("info", "Received SIGUSR1");
		prosody.events.fire_event("signal/SIGUSR1");
	end);

	signal.signal("SIGUSR2", function()
		log("info", "Received SIGUSR2");
		prosody.events.fire_event("signal/SIGUSR2");
	end);
end

function startup.notification_socket()
	local notify_socket_name = os.getenv("NOTIFY_SOCKET");
	if not notify_socket_name then return end
	local have_unix, unix = pcall(require, "socket.unix");
	if not have_unix or type(unix) ~= "table" then
		log("error", "LuaSocket without UNIX socket support, can't notify process manager.")
		return os.exit(1);
	end
	log("debug", "Will notify on socket %q", notify_socket_name);
	notify_socket_name = notify_socket_name:gsub("^@", "\0");
	local notify_socket = unix.dgram();
	local ok, err = notify_socket:setpeername(notify_socket_name);
	if not ok then
		log("error", "Could not connect to notification socket %q: %q", notify_socket_name, err);
		return os.exit(1);
	end
	local time = require "prosody.util.time";

	prosody.notify_socket = notify_socket;
	prosody.events.add_handler("server-started", function()
		notify_socket:send("READY=1");
	end);
	prosody.events.add_handler("reloading-config", function()
		notify_socket:send(string.format("RELOADING=1\nMONOTONIC_USEC=%d", math.floor(time.monotonic() * 1000000)));
	end);
	prosody.events.add_handler("config-reloaded", function()
		notify_socket:send("READY=1");
	end);
	prosody.events.add_handler("server-stopping", function()
		notify_socket:send("STOPPING=1");
	end);
end

function startup.cleanup()
	prosody.log("info", "Shutdown status: Cleaning up");
	prosody.events.fire_event("server-cleanup");
end

function startup.shutdown()
	running_state:begin_shutdown();

	prosody.log("info", "Shutting down...");
	startup.cleanup();
	prosody.events.fire_event("server-stopped");

	running_state:finish_shutdown();

	prosody.log("info", "Shutdown complete");
	prosody.log("debug", "Shutdown reason was: %s", prosody.shutdown_reason or "not specified");
	prosody.log("debug", "Exiting with status code: %d", prosody.shutdown_code or 0);
	server.setquitting(true);
end

function startup.exit()
	os.exit(prosody.shutdown_code, true);
end

-- prosodyctl only
function startup.prosodyctl()
	prosody.process_type = "prosodyctl";
	startup.parse_args();
	startup.init_global_state();
	startup.read_config();
	startup.force_console_logging();
	startup.init_logging();
	startup.init_gc();
	startup.init_errors();
	startup.setup_plugindir();
	startup.setup_plugin_install_path();
	startup.setup_datadir();
	startup.chdir();
	startup.read_version();
	startup.switch_user();
	startup.check_dependencies();
	startup.log_startup_warnings();
	startup.check_unwriteable();
	startup.load_libraries();
	startup.init_http_client();
	startup.make_dummy_hosts();
end

function startup.prosody()
	-- These actions are in a strict order, as many depend on
	-- previous steps to have already been performed
	prosody.process_type = "prosody";
	startup.parse_args();
	startup.init_global_state();
	startup.read_config();
	startup.check_user();
	startup.init_logging();
	startup.init_gc();
	startup.init_errors();
	startup.sanity_check();
	startup.sandbox_require();
	startup.set_function_metatable();
	startup.check_dependencies();
	startup.load_libraries();
	startup.setup_plugindir();
	startup.setup_plugin_install_path();
	startup.setup_datadir();
	startup.chdir();
	startup.add_global_prosody_functions();
	startup.read_version();
	startup.log_greeting();
	startup.log_startup_warnings();
	startup.load_secondary_libraries();
	startup.init_promise();
	startup.init_async();
	startup.instrument();
	startup.init_http_client();
	startup.init_data_store();
	startup.init_global_protection();
	startup.posix_daemonize();
	startup.write_pidfile();
	startup.hook_posix_signals();
	startup.notification_socket();
	startup.prepare_to_start();
	startup.notify_started();
end

return startup;
