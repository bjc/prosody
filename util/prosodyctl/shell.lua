local have_unix, unix = pcall(require, "socket.unix");

if not have_unix or type(unix) ~= "table" then
	print("** LuaSocket unix socket support not available or incompatible, ensure your");
	print("** version is up to date.");
	os.exit(1);
end

local config = require "core.configmanager";
local server = require "net.server";
local st = require "util.stanza";
local path = require "util.paths";

local have_readline, readline = pcall(require, "readline");

local adminstream = require "util.adminstream";

if have_readline then
	readline.set_readline_name("prosody");
end

local function read_line()
	if have_readline then
		return readline.readline("prosody> ");
	else
		io.write("prosody> ");
		return io.read("*line");
	end
end

local function send_line(client, line)
	client.send(st.stanza("repl-input"):text(line));
end

local function repl(client)
	local line = read_line();
	if not line or line == "quit" or line == "exit" or line == "bye" then
		if not line then
			print("");
		end
		os.exit();
	end
	send_line(client, line);
end

local function connection(socket_path, listeners)
	local conn, sock;

	return {
		connect = function ()
			if sock or conn then
				return nil, "already connected";
			end
			sock = unix.stream();
			sock:settimeout(0);
			local ok, err = sock:connect(socket_path);
			if not ok then
				return nil, err;
			end
			conn = server.wrapclient(sock, nil, nil, listeners, "*a");
			return true;
		end;
		disconnect = function ()
			if conn then
				conn:close();
				conn = nil;
			end
			if sock then
				sock:close();
				sock = nil;
			end
			return true;
		end;
	};
end

local function printbanner()
	print([[
                     ____                \   /     _
                    |  _ \ _ __ ___  ___  _-_   __| |_   _
                    | |_) | '__/ _ \/ __|/ _ \ / _` | | | |
                    |  __/| | | (_) \__ \ |_| | (_| | |_| |
                    |_|   |_|  \___/|___/\___/ \__,_|\__, |
                    A study in simplicity            |___/

]]);
	print("Welcome to the Prosody administration console. For a list of commands, type: help");
	print("You may find more help on using this console in our online documentation at ");
	print("https://prosody.im/doc/console\n");
end

local function start(arg) --luacheck: ignore 212/arg
	local client = adminstream.client();

	client.events.add_handler("connected", function ()
		if not arg.quiet then
			printbanner();
		end
		repl(client);
	end);

	client.events.add_handler("disconnected", function ()
		print("--- session closed ---");
		os.exit();
	end);

	client.events.add_handler("received", function (stanza)
		if stanza.name == "repl-output" or stanza.name == "repl-result" then
			local result_prefix = stanza.attr.type == "error" and "!" or "|";
			print(result_prefix.." "..stanza:get_text());
		end
		if stanza.name == "repl-result" then
			repl(client);
		end
	end);

	local socket_path = path.resolve_relative_path(prosody.paths.data, prosody.opts.socket or config.get("*", "admin_socket") or "prosody.sock");
	local conn = connection(socket_path, client.listeners);
	local ok, err = conn:connect();
	if not ok then
		print("** Unable to connect to server - is it running? Is mod_admin_shell enabled?");
		print("** Connection error: "..err);
		os.exit(1);
	end
	server.loop();
end

return {
	shell = start;
};
