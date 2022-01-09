#!/usr/bin/env lua

CFG_SOURCEDIR=CFG_SOURCEDIR or os.getenv("PROSODY_SRCDIR");
CFG_CONFIGDIR=CFG_CONFIGDIR or os.getenv("PROSODY_CFGDIR");
CFG_PLUGINDIR=CFG_PLUGINDIR or os.getenv("PROSODY_PLUGINDIR");
CFG_DATADIR=CFG_DATADIR or os.getenv("PROSODY_DATADIR");

-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --

local function is_relative(path)
	local path_sep = package.config:sub(1,1);
        return ((path_sep == "/" and path:sub(1,1) ~= "/")
	or (path_sep == "\\" and (path:sub(1,1) ~= "/" and path:sub(2,3) ~= ":\\")))
end

-- Tell Lua where to find our libraries
if CFG_SOURCEDIR then
	local function filter_relative_paths(path)
		if is_relative(path) then return ""; end
	end
	local function sanitise_paths(paths)
		return (paths:gsub("[^;]+;?", filter_relative_paths):gsub(";;+", ";"));
	end
	package.path = sanitise_paths(CFG_SOURCEDIR.."/?.lua;"..package.path);
	package.cpath = sanitise_paths(CFG_SOURCEDIR.."/?.so;"..package.cpath);
end

-- Substitute ~ with path to home directory in data path
if CFG_DATADIR then
	if os.getenv("HOME") then
		CFG_DATADIR = CFG_DATADIR:gsub("^~", os.getenv("HOME"));
	end
end

local default_config = (CFG_CONFIGDIR or ".").."/migrator.cfg.lua";

local function usage()
	print("Usage: " .. arg[0] .. " FROM_STORE TO_STORE");
	print("If no stores are specified, 'input' and 'output' are used.");
end

local startup = require "util.startup";
do
	startup.parse_args({
		short_params = { v = "verbose", h = "help", ["?"] = "help" };
		value_params = { config = true };
	});
	startup.init_global_state();
	prosody.process_type = "migrator";
	if prosody.opts.help then
		usage();
		os.exit(0);
	end
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
	prosody.config_loaded = true;
	startup.load_libraries();
	startup.init_http_client();
	prosody.core_post_stanza = function ()
		-- silence assert in core.moduleapi
		error("Attempt to send stanzas from inside migrator.", 0);
	end
end

-- Command-line parsing
local options = prosody.opts;

local envloadfile = require "util.envload".envloadfile;

local config_file = options.config or default_config;
local from_store = arg[1] or "input";
local to_store = arg[2] or "output";

config = {};
local config_env = setmetatable({}, { __index = function(t, k) return function(tbl) config[k] = tbl; end; end });
local config_chunk, err = envloadfile(config_file, config_env);
if not config_chunk then
	print("There was an error loading the config file, check that the file exists");
	print("and that the syntax is correct:");
	print("", err);
	os.exit(1);
end

config_chunk();

local have_err;
if #arg > 0 and #arg ~= 2 then
	have_err = true;
	print("Error: Incorrect number of parameters supplied.");
end
if not config[from_store] then
	have_err = true;
	print("Error: Input store '"..from_store.."' not found in the config file.");
end
if not config[to_store] then
	have_err = true;
	print("Error: Output store '"..to_store.."' not found in the config file.");
end

for store, conf in pairs(config) do -- COMPAT
	if conf.type == "prosody_files" then
		conf.type = "internal";
	elseif conf.type == "prosody_sql" then
		conf.type = "sql";
	end
end

if have_err then
	print("");
	usage();
	print("");
	print("The available stores in your migrator config are:");
	print("");
	for store in pairs(config) do
		print("", store);
	end
	print("");
	os.exit(1);
end

local async = require "util.async";
local server = require "net.server";
local watchers = {
	error = function (_, err)
		error(err);
	end;
	waiting = function ()
		server.loop();
	end;
};

local cm = require "core.configmanager";
local hm = require "core.hostmanager";
local sm = require "core.storagemanager";
local um = require "core.usermanager";

local function users(store, host)
	if store.users then
		return store:users();
	else
		return um.users(host);
	end
end

local function prepare_config(host, conf)
	if conf.type == "internal" then
		sm.olddm.set_data_path(conf.path or prosody.paths.data);
	elseif conf.type == "sql" then
		cm.set(host, "sql", conf);
	end
end

local function get_driver(host, conf)
	prepare_config(host, conf);
	return assert(sm.load_driver(host, conf.type));
end

local migration_runner = async.runner(function (job)
	for host, stores in pairs(job.input.hosts) do
		prosody.hosts[host] = startup.make_host(host);
		sm.initialize_host(host);
		um.initialize_host(host);

		local input_driver = get_driver(host, job.input);

		local output_driver = get_driver(host, job.output);

		for _, store in ipairs(stores) do
			local p, typ = store:match("()%-(%w+)$");
			if typ then store = store:sub(1, p-1); else typ = "keyval"; end
			log("info", "Migrating host %s store %s (%s)", host, store, typ);

			local origin = assert(input_driver:open(store, typ));
			local destination = assert(output_driver:open(store, typ));

			if typ == "keyval" then -- host data
				local data, err = origin:get(nil);
				assert(not err, err);
				assert(destination:set(nil, data));
			end

			for user in users(origin, host) do
				if typ == "keyval" then
					local data, err = origin:get(user);
					assert(not err, err);
					assert(destination:set(user, data));
				elseif typ == "archive" then
					local iter, err = origin:find(user);
					assert(iter, err);
					for id, item, when, with in iter do
						assert(destination:append(user, id, item, when, with));
					end
				else
					error("Don't know how to migrate data of type '"..typ.."'.");
				end
			end
		end
	end
end, watchers);

io.stderr:write("Migrating...\n");

migration_runner:run({ input = config[from_store], output = config[to_store] });

io.stderr:write("Done!\n");
