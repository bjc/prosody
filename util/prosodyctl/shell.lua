local config = require "prosody.core.configmanager";
local human_io = require "prosody.util.human.io";
local server = require "prosody.net.server";
local st = require "prosody.util.stanza";
local path = require "prosody.util.paths";
local parse_args = require "prosody.util.argparse".parse;
local tc = require "prosody.util.termcolours";
local isatty = require "prosody.util.pposix".isatty;
local term_width = require"prosody.util.human.io".term_width;

local have_readline, readline = pcall(require, "readline");

local adminstream = require "prosody.util.adminstream";

if have_readline then
	readline.set_readline_name("prosody");
	readline.set_options({
			histfile = path.join(prosody.paths.data, ".shell_history");
			ignoredups = true;
		});
end

local function read_line(prompt_string)
	if have_readline then
		return readline.readline(prompt_string);
	else
		io.write(prompt_string);
		return io.read("*line");
	end
end

local function send_line(client, line)
	client.send(st.stanza("repl-input", { width = tostring(term_width()) }):text(line));
end

local function repl(client)
	local line = read_line(client.prompt_string or "prosody> ");
	if not line or line == "quit" or line == "exit" or line == "bye" then
		if not line then
			print("");
		end
		if have_readline then
			readline.save_history();
		end
		os.exit(0, true);
	end
	send_line(client, line);
end

local function printbanner()
	local banner = config.get("*", "console_banner");
	if banner then return print(banner); end
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
	local opts, err, where = parse_args(arg);
	local ttyout = isatty(io.stdout);

	if not opts then
		if err == "param-not-found" then
			print("Unknown command-line option: "..tostring(where));
		elseif err == "missing-value" then
			print("Expected a value to follow command-line option: "..where);
		end
		os.exit(1);
	end

	if arg[1] then
		if arg[2] then
			local fmt = { "%s"; ":%s("; ")" };
			for i = 3, #arg do
				if arg[i]:sub(1, 1) == ":" then
					table.insert(fmt, i, ")%s(");
				elseif i > 3 and fmt[i - 1]:match("%%q$") then
					table.insert(fmt, i, ", %q");
				else
					table.insert(fmt, i, "%q");
				end
			end
			arg[1] = string.format(table.concat(fmt), table.unpack(arg));
		end

		client.events.add_handler("connected", function()
			send_line(client, arg[1]);
			return true;
		end, 1);

		local errors = 0; -- TODO This is weird, but works for now.
		client.events.add_handler("received", function(stanza)
			if stanza.name == "repl-output" or stanza.name == "repl-result" then
				local dest = io.stdout;
				if stanza.attr.type == "error" then
					errors = errors + 1;
					dest = io.stderr;
				end
				if stanza.attr.eol == "0" then
					dest:write(stanza:get_text());
				else
					dest:write(stanza:get_text(), "\n");
				end
			end
			if stanza.name == "repl-result" then
				os.exit(errors);
			end
			return true;
		end, 1);
	end

	client.events.add_handler("connected", function ()
		if not opts.quiet then
			printbanner();
		end
		repl(client);
	end);

	client.events.add_handler("disconnected", function ()
		print("--- session closed ---");
		os.exit(0, true);
	end);

	client.events.add_handler("received", function (stanza)
		if stanza.name ~= "repl-request-input" then
			return;
		end
		if stanza.attr.type == "password" then
			local password = human_io.read_password();
			client.send(st.stanza("repl-requested-input", { type = stanza.attr.type, id = stanza.attr.id }):text(password));
		else
			io.stderr:write("Internal error - unexpected input request type "..tostring(stanza.attr.type).."\n");
			os.exit(1);
		end
		return true;
	end, 2);


	client.events.add_handler("received", function (stanza)
		if stanza.name == "repl-output" or stanza.name == "repl-result" then
			local result_prefix = stanza.attr.type == "error" and "!" or "|";
			local out = result_prefix.." "..stanza:get_text();
			if ttyout and stanza.attr.type == "error" then
				out = tc.getstring(tc.getstyle("red"), out);
			end
			print(out);
		end
		if stanza.name == "repl-result" then
			repl(client);
		end
	end);

	client.prompt_string = config.get("*", "admin_shell_prompt");

	local socket_path = path.resolve_relative_path(prosody.paths.data, opts.socket or config.get("*", "admin_socket") or "prosody.sock");
	local conn = adminstream.connection(socket_path, client.listeners);
	local ok, err = conn:connect();
	if not ok then
		if err == "no unix socket support" then
			print("** LuaSocket unix socket support not available or incompatible, ensure your");
			print("** version is up to date.");
		else
			print("** Unable to connect to server - is it running? Is mod_admin_shell enabled?");
			print("** Connection error: "..err);
		end
		os.exit(1);
	end
	server.loop();
end

return {
	shell = start;
};
