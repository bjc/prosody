
local connlisteners_register = require "net.connlisteners".register;

local console_listener = { default_port = 5582; default_mode = "*l"; };

local commands = {};
local default_env = {};
local default_env_mt = { __index = default_env };

console = {};

function console:new_session(conn)
	local w = conn.write;
	return { conn = conn;
			send = function (t) w(tostring(t)); end;
			print = function (t) w("| "..tostring(t).."\n"); end;
			disconnect = function () conn.close(); end;
			env = setmetatable({}, default_env_mt);
			};
end

local sessions = {};

function console_listener.listener(conn, data)
	local session = sessions[conn];
	
	if not session then
		-- Handle new connection
		session = console:new_session(conn);
		sessions[conn] = session;
		session.print("Welcome to the lxmppd admin console!");
	end
	if data then
		-- Handle data
		
		if data:match("[!.]$") then
			local command = data:lower();
			command = data:match("^%w+") or data:match("%p");
			if commands[command] then
				commands[command](session, data);
				return;
			end
		end
		
		session.env._ = data;
		
		local chunk, err = loadstring("return "..data);
		if not chunk then
			chunk, err = loadstring(data);
			if not chunk then
				err = err:gsub("^%[string .-%]:%d+: ", "");
				err = err:gsub("^:%d+: ", "");
				err = err:gsub("'<eof>'", "the end of the line");
				session.print("Sorry, I couldn't understand that... "..err);
				return;
			end
		end
		
		setfenv(chunk, session.env);
		local ranok, taskok, message = pcall(chunk);
		
		if not ranok then
			session.print("Fatal error while running command, it did not complete");
			session.print("Error: "..taskok);
			return;
		end
		
		if not message then
			session.print("Result: "..tostring(taskok));
			return;
		elseif (not taskok) and message then
			session.print("Command completed with a problem");
			session.print("Message: "..tostring(message));
			return;
		end
		
		session.print("OK: "..tostring(message));
	end
end

function console_listener.disconnect(conn, err)
	
end

connlisteners_register('console', console_listener);

-- Console commands --
-- These are simple commands, not valid standalone in Lua

function commands.bye(session)
	session.print("See you! :)");
	session.disconnect();
end

commands["!"] = function (session, data)
	if data:match("^!!") then
		session.print("!> "..session.env._);
		return console_listener.listener(session.conn, session.env._);
	end
	local old, new = data:match("^!(.-[^\\])!(.-)!$");
	if old and new then
		local ok, res = pcall(string.gsub, session.env._, old, new);
		if not ok then
			session.print(res)
			return;
		end
		session.print("!> "..res);
		return console_listener.listener(session.conn, res);
	end
	session.print("Sorry, not sure what you want");
end

-- Session environment --
-- Anything in default_env will be accessible within the session as a global variable

default_env.server = {};
function default_env.server.reload()
	dofile "main.lua"
	return true, "Server reloaded";
end

default_env.module = {};
function default_env.module.load(name)
	local mm = require "modulemanager";
	local ok, err = mm.load(name);
	if not ok then
		return false, err or "Unknown error loading module";
	end
	return true, "Module loaded";
end

default_env.config = {};
function default_env.config.load(filename, format)
	local cfgm_load = require "core.configmanager".load;
	local ok, err = cfgm_load(filename, format);
	if not ok then
		return false, err or "Unknown error loading config";
	end
	return true, "Config loaded";
end
