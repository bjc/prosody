-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- luacheck: ignore 212/self

module:set_global();
module:depends("admin_shell");

local console_listener = { default_port = 5582; default_mode = "*a"; interface = "127.0.0.1" };

local async = require "util.async";
local st = require "util.stanza";

local def_env = module:shared("admin_shell/env");
local default_env_mt = { __index = def_env };

local function printbanner(session)
	local option = module:get_option_string("console_banner", "full");
	if option == "full" or option == "graphic" then
		session.print [[
                   ____                \   /     _
                    |  _ \ _ __ ___  ___  _-_   __| |_   _
                    | |_) | '__/ _ \/ __|/ _ \ / _` | | | |
                    |  __/| | | (_) \__ \ |_| | (_| | |_| |
                    |_|   |_|  \___/|___/\___/ \__,_|\__, |
                    A study in simplicity            |___/

]]
	end
	if option == "short" or option == "full" then
	session.print("Welcome to the Prosody administration console. For a list of commands, type: help");
	session.print("You may find more help on using this console in our online documentation at ");
	session.print("https://prosody.im/doc/console\n");
	end
	if option ~= "short" and option ~= "full" and option ~= "graphic" then
		session.print(option);
	end
end

console = {};

local runner_callbacks = {};

function runner_callbacks:ready()
	self.data.conn:resume();
end

function runner_callbacks:waiting()
	self.data.conn:pause();
end

function runner_callbacks:error(err)
	module:log("error", "Traceback[telnet]: %s", err);

	self.data.print("Fatal error while running command, it did not complete");
	self.data.print("Error: "..tostring(err));
end


function console:new_session(conn)
	local w = function(s) conn:write(s:gsub("\n", "\r\n")); end;
	local session = { conn = conn;
			send = function (t)
				if st.is_stanza(t) and t.name == "repl-result" then
					t = "| "..t:get_text().."\n";
				end
				w(tostring(t));
			end;
			print = function (...)
				local t = {};
				for i=1,select("#", ...) do
					t[i] = tostring(select(i, ...));
				end
				w("| "..table.concat(t, "\t").."\n");
			end;
			serialize = tostring;
			disconnect = function () conn:close(); end;
			};
	session.env = setmetatable({}, default_env_mt);

	session.thread = async.runner(function (line)
		console:process_line(session, line);
		session.send(string.char(0));
	end, runner_callbacks, session);

	-- Load up environment with helper objects
	for name, t in pairs(def_env) do
		if type(t) == "table" then
			session.env[name] = setmetatable({ session = session }, { __index = t });
		end
	end

	session.env.output:configure();

	return session;
end

function console:process_line(session, line)
	line = line:gsub("\r?\n$", "");
	if line == "bye" or line == "quit" or line == "exit" or line:byte() == 4 then
		session.print("See you!");
		session:disconnect();
		return;
	end
	return module:fire_event("admin/repl-line", { origin = session, stanza = st.stanza("repl"):text(line) });
end

local sessions = {};

function module.save()
	return { sessions = sessions }
end

function module.restore(data)
	if data.sessions then
		for conn in pairs(data.sessions) do
			conn:setlistener(console_listener);
			local session = console:new_session(conn);
			sessions[conn] = session;
		end
	end
end

function console_listener.onconnect(conn)
	-- Handle new connection
	local session = console:new_session(conn);
	sessions[conn] = session;
	printbanner(session);
	session.send(string.char(0));
end

function console_listener.onincoming(conn, data)
	local session = sessions[conn];

	local partial = session.partial_data;
	if partial then
		data = partial..data;
	end

	for line in data:gmatch("[^\n]*[\n\004]") do
		if session.closed then return end
		session.thread:run(line);
	end
	session.partial_data = data:match("[^\n]+$");
end

function console_listener.onreadtimeout(conn)
	local session = sessions[conn];
	if session then
		session.send("\0");
		return true;
	end
end

function console_listener.ondisconnect(conn, err) -- luacheck: ignore 212/err
	local session = sessions[conn];
	if session then
		session.disconnect();
		sessions[conn] = nil;
	end
end

function console_listener.ondetach(conn)
	sessions[conn] = nil;
end

module:provides("net", {
	name = "console";
	listener = console_listener;
	default_port = 5582;
	private = true;
});
