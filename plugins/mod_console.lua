
local connlisteners_register = require "net.connlisteners".register;

local console_listener = { default_port = 5582; default_mode = "*l"; };

local commands = {};
local def_env = {};
local default_env_mt = { __index = def_env };

console = {};

function console:new_session(conn)
	local w = conn.write;
	local session = { conn = conn;
			send = function (t) w(tostring(t)); end;
			print = function (t) w("| "..tostring(t).."\n"); end;
			disconnect = function () conn.close(); end;
			};
	session.env = setmetatable({}, default_env_mt);
	
	-- Load up environment with helper objects
	for name, t in pairs(def_env) do
		if type(t) == "table" then
			session.env[name] = setmetatable({ session = session }, { __index = t });
		end
	end
	
	return session;
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
-- Anything in def_env will be accessible within the session as a global variable

def_env.server = {};
function def_env.server:reload()
	dofile "main.lua"
	return true, "Server reloaded";
end

def_env.module = {};
function def_env.module:load(name)
	local mm = require "modulemanager";
	local ok, err = mm.load(name);
	if not ok then
		return false, err or "Unknown error loading module";
	end
	return true, "Module loaded";
end

def_env.config = {};
function def_env.config:load(filename, format)
	local config_load = require "core.configmanager".load;
	local ok, err = config_load(filename, format);
	if not ok then
		return false, err or "Unknown error loading config";
	end
	return true, "Config loaded";
end

function def_env.config:get(host, section, key)
	local config_get = require "core.configmanager".get
	return true, tostring(config_get(host, section, key));
end

def_env.hosts = {};
function def_env.hosts:list()
	for host, host_session in pairs(hosts) do
		self.session.print(host);
	end
	return true, "Done";
end

function def_env.hosts:add(name)
end
