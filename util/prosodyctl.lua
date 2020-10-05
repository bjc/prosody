-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local config = require "core.configmanager";
local encodings = require "util.encodings";
local stringprep = encodings.stringprep;
local storagemanager = require "core.storagemanager";
local usermanager = require "core.usermanager";
local interpolation = require "util.interpolation";
local signal = require "util.signal";
local set = require "util.set";
local lfs = require "lfs";
local type = type;

local nodeprep, nameprep = stringprep.nodeprep, stringprep.nameprep;

local io, os = io, os;
local print = print;
local tonumber = tonumber;

local _G = _G;
local prosody = prosody;

local error_messages = setmetatable({
		["invalid-username"] = "The given username is invalid in a Jabber ID";
		["invalid-hostname"] = "The given hostname is invalid";
		["no-password"] = "No password was supplied";
		["no-such-user"] = "The given user does not exist on the server";
		["no-such-host"] = "The given hostname does not exist in the config";
		["unable-to-save-data"] = "Unable to store, perhaps you don't have permission?";
		["no-pidfile"] = "There is no 'pidfile' option in the configuration file, see https://prosody.im/doc/prosodyctl#pidfile for help";
		["invalid-pidfile"] = "The 'pidfile' option in the configuration file is not a string, see https://prosody.im/doc/prosodyctl#pidfile for help";
		["no-posix"] = "The mod_posix module is not enabled in the Prosody config file, see https://prosody.im/doc/prosodyctl for more info";
		["no-such-method"] = "This module has no commands";
		["not-running"] = "Prosody is not running";
		}, { __index = function (_,k) return "Error: "..(tostring(k):gsub("%-", " "):gsub("^.", string.upper)); end });

-- UI helpers
local show_message = require "util.human.io".printf;

local function show_usage(usage, desc)
	print("Usage: ".._G.arg[0].." "..usage);
	if desc then
		print(" "..desc);
	end
end

local function show_module_configuration_help(mod_name)
	print("Done.")
	print("If you installed a prosody plugin, don't forget to add its name under the 'modules_enabled' section inside your configuration file.")
	print("Depending on the module, there might be further configuration steps required.")
	print("")
	print("More info about: ")
	print("	modules_enabled: https://prosody.im/doc/modules_enabled")
	print("	"..mod_name..": https://modules.prosody.im/"..mod_name..".html")
end

-- Server control
local function adduser(params)
	local user, host, password = nodeprep(params.user, true), nameprep(params.host), params.password;
	if not user then
		return false, "invalid-username";
	elseif not host then
		return false, "invalid-hostname";
	end

	local host_session = prosody.hosts[host];
	if not host_session then
		return false, "no-such-host";
	end

	storagemanager.initialize_host(host);
	local provider = host_session.users;
	if not(provider) or provider.name == "null" then
		usermanager.initialize_host(host);
	end

	local ok, errmsg = usermanager.create_user(user, password, host);
	if not ok then
		return false, errmsg or "creating-user-failed";
	end
	return true;
end

local function user_exists(params)
	local user, host = nodeprep(params.user), nameprep(params.host);

	storagemanager.initialize_host(host);
	local provider = prosody.hosts[host].users;
	if not(provider) or provider.name == "null" then
		usermanager.initialize_host(host);
	end

	return usermanager.user_exists(user, host);
end

local function passwd(params)
	if not user_exists(params) then
		return false, "no-such-user";
	end

	return adduser(params);
end

local function deluser(params)
	if not user_exists(params) then
		return false, "no-such-user";
	end
	local user, host = nodeprep(params.user), nameprep(params.host);

	return usermanager.delete_user(user, host);
end

local function getpid()
	local pidfile = config.get("*", "pidfile");
	if not pidfile then
		return false, "no-pidfile";
	end

	if type(pidfile) ~= "string" then
		return false, "invalid-pidfile";
	end

	pidfile = config.resolve_relative_path(prosody.paths.data, pidfile);

	local modules_disabled = set.new(config.get("*", "modules_disabled"));
	if prosody.platform ~= "posix" or modules_disabled:contains("posix") then
		return false, "no-posix";
	end

	local file, err = io.open(pidfile, "r+");
	if not file then
		return false, "pidfile-read-failed", err;
	end

	local locked, err = lfs.lock(file, "w"); -- luacheck: ignore 211/err
	if locked then
		file:close();
		return false, "pidfile-not-locked";
	end

	local pid = tonumber(file:read("*a"));
	file:close();

	if not pid then
		return false, "invalid-pid";
	end

	return true, pid;
end

local function isrunning()
	local ok, pid, err = getpid(); -- luacheck: ignore 211/err
	if not ok then
		if pid == "pidfile-read-failed" or pid == "pidfile-not-locked" then
			-- Report as not running, since we can't open the pidfile
			-- (it probably doesn't exist)
			return true, false;
		end
		return ok, pid;
	end
	return true, signal.kill(pid, 0) == 0;
end

local function start(source_dir, lua)
	lua = lua and lua .. " " or "";
	local ok, ret = isrunning();
	if not ok then
		return ok, ret;
	end
	if ret then
		return false, "already-running";
	end
	if not source_dir then
		os.execute(lua .. "./prosody -D");
	else
		os.execute(lua .. source_dir.."/../../bin/prosody -D");
	end
	return true;
end

local function stop()
	local ok, ret = isrunning();
	if not ok then
		return ok, ret;
	end
	if not ret then
		return false, "not-running";
	end

	local ok, pid = getpid()
	if not ok then return false, pid; end

	signal.kill(pid, signal.SIGTERM);
	return true;
end

local function reload()
	local ok, ret = isrunning();
	if not ok then
		return ok, ret;
	end
	if not ret then
		return false, "not-running";
	end

	local ok, pid = getpid()
	if not ok then return false, pid; end

	signal.kill(pid, signal.SIGHUP);
	return true;
end

local function get_path_custom_plugins(plugin_paths)
		-- I'm considering that the custom plugins' path is the first one at prosody.paths.plugins
	-- luacheck: ignore 512
	for path in plugin_paths:gmatch("[^;]+") do
		return path;
	end
end

local render_cli = interpolation.new("%b{}", function (s) return "'"..s:gsub("'","'\\''").."'" end)

local function call_luarocks(mod, operation)
	local dir = get_path_custom_plugins(prosody.paths.plugins);
	if operation == "install" then
		show_message("Installing %s at %s", mod, dir);
	elseif operation == "remove" then
		show_message("Removing %s from %s", mod, dir);
	end
	if operation == "list" then
		os.execute(render_cli("luarocks list --tree={dir}", {dir = dir}));
	else
		os.execute(render_cli("luarocks {op} --tree={dir} {server&--server={server}} {mod}", {
					dir = dir; op = operation; mod = mod; server = "http://localhost/";
			}));
	end
	if operation == "install" then
		show_module_configuration_help(mod);
	end
end

return {
	show_message = show_message;
	show_warning = show_message;
	show_usage = show_usage;
	show_module_configuration_help = show_module_configuration_help;
	adduser = adduser;
	user_exists = user_exists;
	passwd = passwd;
	deluser = deluser;
	getpid = getpid;
	isrunning = isrunning;
	start = start;
	stop = stop;
	reload = reload;
	get_path_custom_plugins = get_path_custom_plugins;
	call_luarocks = call_luarocks;
	error_messages = error_messages;
};
