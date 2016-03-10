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
local signal = require "util.signal";
local set = require "util.set";
local lfs = require "lfs";
local pcall = pcall;
local type = type;

local nodeprep, nameprep = stringprep.nodeprep, stringprep.nameprep;

local io, os = io, os;
local print = print;
local tonumber = tonumber;

local CFG_SOURCEDIR = _G.CFG_SOURCEDIR;

local _G = _G;
local prosody = prosody;

-- UI helpers
local function show_message(msg, ...)
	print(msg:format(...));
end

local function show_usage(usage, desc)
	print("Usage: ".._G.arg[0].." "..usage);
	if desc then
		print(" "..desc);
	end
end

local function getchar(n)
	local stty_ret = os.execute("stty raw -echo 2>/dev/null");
	local ok, char;
	if stty_ret == 0 then
		ok, char = pcall(io.read, n or 1);
		os.execute("stty sane");
	else
		ok, char = pcall(io.read, "*l");
		if ok then
			char = char:sub(1, n or 1);
		end
	end
	if ok then
		return char;
	end
end

local function getline()
	local ok, line = pcall(io.read, "*l");
	if ok then
		return line;
	end
end

local function getpass()
	local stty_ret = os.execute("stty -echo 2>/dev/null");
	if stty_ret ~= 0 then
		io.write("\027[08m"); -- ANSI 'hidden' text attribute
	end
	local ok, pass = pcall(io.read, "*l");
	if stty_ret == 0 then
		os.execute("stty sane");
	else
		io.write("\027[00m");
	end
	io.write("\n");
	if ok then
		return pass;
	end
end

local function show_yesno(prompt)
	io.write(prompt, " ");
	local choice = getchar():lower();
	io.write("\n");
	if not choice:match("%a") then
		choice = prompt:match("%[.-(%U).-%]$");
		if not choice then return nil; end
	end
	return (choice == "y");
end

local function read_password()
	local password;
	while true do
		io.write("Enter new password: ");
		password = getpass();
		if not password then
			show_message("No password - cancelled");
			return;
		end
		io.write("Retype new password: ");
		if getpass() ~= password then
			if not show_yesno [=[Passwords did not match, try again? [Y/n]]=] then
				return;
			end
		else
			break;
		end
	end
	return password;
end

local function show_prompt(prompt)
	io.write(prompt, " ");
	local line = getline();
	line = line and line:gsub("\n$","");
	return (line and #line > 0) and line or nil;
end

-- Server control
local function adduser(params)
	local user, host, password = nodeprep(params.user), nameprep(params.host), params.password;
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

	local modules_enabled = set.new(config.get("*", "modules_disabled"));
	if prosody.platform ~= "posix" or modules_enabled:contains("posix") then
		return false, "no-posix";
	end

	local file, err = io.open(pidfile, "r+");
	if not file then
		return false, "pidfile-read-failed", err;
	end

	local locked, err = lfs.lock(file, "w");
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
	local ok, pid, err = getpid();
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

local function start()
	local ok, ret = isrunning();
	if not ok then
		return ok, ret;
	end
	if ret then
		return false, "already-running";
	end
	if not CFG_SOURCEDIR then
		os.execute("./prosody");
	else
		os.execute(CFG_SOURCEDIR.."/../../bin/prosody");
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

return {
	show_message = show_message;
	show_warning = show_message;
	show_usage = show_usage;
	getchar = getchar;
	getline = getline;
	getpass = getpass;
	show_yesno = show_yesno;
	read_password = read_password;
	show_prompt = show_prompt;
	adduser = adduser;
	user_exists = user_exists;
	passwd = passwd;
	deluser = deluser;
	getpid = getpid;
	isrunning = isrunning;
	start = start;
	stop = stop;
	reload = reload;
};
