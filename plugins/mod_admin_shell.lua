-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- luacheck: ignore 212/self

module:set_global();
module:depends("admin_socket");

local hostmanager = require "prosody.core.hostmanager";
local modulemanager = require "prosody.core.modulemanager";
local s2smanager = require "prosody.core.s2smanager";
local portmanager = require "prosody.core.portmanager";
local helpers = require "prosody.util.helpers";
local it = require "prosody.util.iterators";
local server = require "prosody.net.server";
local schema = require "prosody.util.jsonschema";
local st = require "prosody.util.stanza";

local _G = _G;

local prosody = _G.prosody;

local unpack = table.unpack;
local cache = require "prosody.util.cache";
local new_short_id = require "prosody.util.id".short;
local iterators = require "prosody.util.iterators";
local keys, values = iterators.keys, iterators.values;
local jid_bare, jid_split, jid_join, jid_resource, jid_compare = import("prosody.util.jid", "bare", "prepped_split", "join", "resource", "compare");
local set, array = require "prosody.util.set", require "prosody.util.array";
local cert_verify_identity = require "prosody.util.x509".verify_identity;
local envload = require "prosody.util.envload".envload;
local envloadfile = require "prosody.util.envload".envloadfile;
local has_pposix, pposix = pcall(require, "prosody.util.pposix");
local async = require "prosody.util.async";
local serialization = require "prosody.util.serialization";
local serialize_config = serialization.new ({ fatal = false, unquoted = true});
local time = require "prosody.util.time";
local promise = require "prosody.util.promise";
local logger = require "prosody.util.logger";

local t_insert = table.insert;
local t_concat = table.concat;

local format_number = require "prosody.util.human.units".format;
local format_table = require "prosody.util.human.io".table;

local function capitalize(s)
	if not s then return end
	return (s:gsub("^%a", string.upper):gsub("_", " "));
end

local function pre(prefix, str, alt)
	if type(str) ~= "string" or str == "" then return alt or ""; end
	return prefix .. str;
end

local function suf(str, suffix, alt)
	if type(str) ~= "string" or str == "" then return alt or ""; end
	return str .. suffix;
end

local commands = module:shared("commands")
local def_env = module:shared("env");
local default_env_mt = { __index = def_env };

local function new_section(section_desc)
	return setmetatable({}, {
		help = {
			desc = section_desc;
			commands = {};
		};
	});
end

local help_topics = {};
local function help_topic(name)
	return function (desc)
		return function (content)
			help_topics[name] = {
				desc = desc;
				content = content;
			};
		end;
	end
end

-- Seed with default sections and their description text
help_topic "console" "Help regarding the console itself" [[
Hey! Welcome to Prosody's admin console.
First thing, if you're ever wondering how to get out, simply type 'quit'.
Secondly, note that we don't support the full telnet protocol yet (it's coming)
so you may have trouble using the arrow keys, etc. depending on your system.

For now we offer a couple of handy shortcuts:
!! - Repeat the last command
!old!new! - repeat the last command, but with 'old' replaced by 'new'

For those well-versed in Prosody's internals, or taking instruction from those who are,
you can prefix a command with > to escape the console sandbox, and access everything in
the running server. Great fun, but be careful not to break anything :)
]];

local available_columns; --forward declaration so it is reachable from the help

help_topic "columns" "Information about customizing session listings" (function (self, print)
	print [[The columns shown by c2s:show() and s2s:show() can be customizied via the]]
	print [['columns' argument as described here.]]
	print [[]]
	print [[Columns can be specified either as "id jid ipv" or as {"id", "jid", "ipv"}.]]
	print [[Available columns are:]]
	local meta_columns = {
		{ title = "ID"; width = 5 };
		{ title = "Column Title"; width = 12 };
		{ title = "Description"; width = 12 };
	};
	-- auto-adjust widths
	for column, spec in pairs(available_columns) do
		meta_columns[1].width = math.max(meta_columns[1].width or 0, #column);
		meta_columns[2].width = math.max(meta_columns[2].width or 0, #(spec.title or ""));
		meta_columns[3].width = math.max(meta_columns[3].width or 0, #(spec.description or ""));
	end
	local row = format_table(meta_columns, self.session.width)
	print(row());
	for column, spec in iterators.sorted_pairs(available_columns) do
		print(row({ column, spec.title, spec.description }));
	end
	print [[]]
	print [[Most fields on the internal session structures can also be used as columns]]
	-- Also, you can pass a table column specification directly, with mapper callback and all
end);

help_topic "roles"   "Show information about user roles" [[
Roles may grant access or restrict users from certain operations.

Built-in roles are:
  prosody:guest      - Guest/anonymous user
  prosody:registered - Registered user
  prosody:member     - Provisioned user
  prosody:admin      - Host administrator
  prosody:operator - Server administrator

Roles can be assigned using the user management commands (see 'help user').
]];


local function redirect_output(target, session)
	local env = setmetatable({ print = session.print }, { __index = function (_, k) return rawget(target, k); end });
	env.dofile = function(name)
		local f, err = envloadfile(name, env);
		if not f then return f, err; end
		return f();
	end;
	return env;
end

console = {};

local runner_callbacks = {};

function runner_callbacks:error(err)
	module:log("error", "Traceback[shell]: %s", err);

	self.data.print("Fatal error while running command, it did not complete");
	self.data.print("Error: "..tostring(err));
end

local function send_repl_output(session, line, attr)
	return session.send(st.stanza("repl-output", attr):text(tostring(line)));
end

local function request_repl_input(session, input_type)
	if input_type ~= "password" then
		return promise.reject("internal error - unsupported input type "..tostring(input_type));
	end
	local pending_inputs = session.pending_inputs;
	if not pending_inputs then
		pending_inputs = cache.new(5, function (input_id, input_promise) --luacheck: ignore 212/input_id
			input_promise.reject();
		end);
		session.pending_inputs = pending_inputs;
	end

	local input_id = new_short_id();
	local p = promise.new(function (resolve, reject)
		pending_inputs:set(input_id, { resolve = resolve, reject = reject });
	end):finally(function ()
		pending_inputs:set(input_id, nil);
	end);
	session.send(st.stanza("repl-request-input", { type = input_type, id = input_id }));
	return p;
end

module:hook("admin-disconnected", function (event)
	local pending_inputs = event.session.pending_inputs;
	if not pending_inputs then return; end
	for input_promise in pending_inputs:values() do
		input_promise.reject();
	end
end);

module:hook("admin/repl-requested-input", function (event)
	local input_id = event.stanza.attr.id;
	local input_promise = event.origin.pending_inputs:get(input_id);
	if not input_promise then
		event.origin.send(st.stanza("repl-result", { type = "error" }):text("Internal error - unexpected input"));
		return true;
	end
	input_promise.resolve(event.stanza:get_text());
	return true;
end);

function console:new_session(admin_session)
	local session = {
		send = function (t)
			return send_repl_output(admin_session, t);
		end;
		print = function (...)
			local t = {};
			for i=1,select("#", ...) do
				t[i] = tostring(select(i, ...));
			end
			return send_repl_output(admin_session, table.concat(t, "\t"));
		end;
		write = function (t)
			return send_repl_output(admin_session, t, { eol = "0" });
		end;
		request_input = function (input_type)
			return request_repl_input(admin_session, input_type);
		end;
		serialize = tostring;
		disconnect = function () admin_session:close(); end;
		is_connected = function ()
			return not not admin_session.conn;
		end
	};
	session.env = setmetatable({}, default_env_mt);

	session.thread = async.runner(function (line)
		console:process_line(session, line);
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

local function handle_line(event)
	local session = event.origin.shell_session;
	if not session then
		session = console:new_session(event.origin);
		event.origin.shell_session = session;
	end

	local default_width = 132; -- The common default of 80 is a bit too narrow for e.g. s2s:show(), 132 was another common width for hardware terminals
	local margin = 2; -- To account for '| ' when lines are printed
	session.width = (tonumber(event.stanza.attr.width) or default_width)-margin;

	local line = event.stanza:get_text();
	local useglobalenv;

	local result = st.stanza("repl-result");

	if line:match("^>") then
		line = line:gsub("^>", "");
		useglobalenv = true;
	else
		local command = line:match("^(%w+) ") or line:match("^%w+$") or line:match("%p");
		if commands[command] then
			commands[command](session, line);
			event.origin.send(result);
			return;
		end
	end

	session.env._ = line;

	if not useglobalenv and commands[line:lower()] then
		commands[line:lower()](session, line);
		event.origin.send(result);
		return;
	end

	if useglobalenv and not session.globalenv then
		session.globalenv = redirect_output(_G, session);
	end

	local chunkname = "=console";
	local env = (useglobalenv and session.globalenv) or session.env or nil
	-- luacheck: ignore 311/err
	local chunk, err = envload("return "..line, chunkname, env);
	if not chunk then
		chunk, err = envload(line, chunkname, env);
		if not chunk then
			err = err:gsub("^%[string .-%]:%d+: ", "");
			err = err:gsub("^:%d+: ", "");
			err = err:gsub("'<eof>'", "the end of the line");
			result.attr.type = "error";
			result:text("Sorry, I couldn't understand that... "..err);
			event.origin.send(result);
			return;
		end
	end

	local function send_result(taskok, message)
		if not message then
			if type(taskok) ~= "string" and useglobalenv then
				taskok = session.serialize(taskok);
			end
			result:text("Result: "..tostring(taskok));
		elseif (not taskok) and message then
			result.attr.type = "error";
			result:text("Error: "..tostring(message));
		else
			result:text("OK: "..tostring(message));
		end

		event.origin.send(result);
	end

	local taskok, message = chunk();

	if promise.is_promise(taskok) then
		taskok:next(function (resolved_message)
			send_result(true, resolved_message);
		end, function (rejected_message)
			send_result(nil, rejected_message);
		end);
	else
		send_result(taskok, message);
	end
end

module:hook("admin/repl-input", function (event)
	local ok, err = pcall(handle_line, event);
	if not ok then
		event.origin.send(st.stanza("repl-result", { type = "error" }):text(err));
	end
	return true;
end);

local function describe_command(s)
	local section, name, args, desc = s:match("^([%w_]+):([%w_]+)%(([^)]*)%) %- (.+)$");
	if not section then
		error("Failed to parse command description: "..s);
	end
	local command_help = getmetatable(def_env[section]).help.commands;
	command_help[name] = {
		desc = desc;
		args = array.collect(args:gmatch("[%w_]+")):map(function (arg_name)
			return { name = arg_name };
		end);
	};
end

-- Console commands --
-- These are simple commands, not valid standalone in Lua

-- Help about individual topics is handled by def_env.help
function commands.help(session, data)
	local print = session.print;

	local topic = data:match("^help (%w+)");
	if topic then
		return def_env.help[topic]({ session = session });
	end

	print [[Commands are divided into multiple sections. For help on a particular section, ]]
	print [[type: help SECTION (for example, 'help c2s'). Sections are: ]]
	print [[]]
	local row = format_table({ { title = "Section", width = 7 }, { title = "Description", width = "100%" } }, session.width)
	print(row())
	for section_name, section in it.sorted_pairs(def_env) do
		local section_mt = getmetatable(section);
		local section_help = section_mt and section_mt.help;
		print(row { section_name; section_help and section_help.desc or "" });
	end

	print("");

	print [[In addition to info about commands, the following general topics are available:]]

	print("");
	for topic_name, topic_info in it.sorted_pairs(help_topics) do
		print(topic_name .. " - "..topic_info.desc);
	end
end

-- Session environment --
-- Anything in def_env will be accessible within the session as a global variable

--luacheck: ignore 212/self
local serialize_defaults = module:get_option("console_prettyprint_settings", {
	preset = "pretty";
	maxdepth = 2;
	table_iterator = "pairs";
})

def_env.output = new_section("Configure admin console output");
function def_env.output:configure(opts)
	if type(opts) ~= "table" then
		opts = { preset = opts };
	end
	if not opts.fallback then
		-- XXX Error message passed to fallback is lost, does it matter?
		opts.fallback = tostring;
	end
	for k,v in pairs(serialize_defaults) do
		if opts[k] == nil then
			opts[k] = v;
		end
	end
	if opts.table_iterator == "pairs" then
		opts.table_iterator = pairs;
	elseif type(opts.table_iterator) ~= "function" then
		opts.table_iterator = nil; -- rawpairs is the default
	end
	self.session.serialize = serialization.new(opts);
end

def_env.help = setmetatable({}, {
	help = {
		desc = "Show this help about available commands";
		commands = {};
	};
	__index = function (_, section_name)
		return function (self)
			local print = self.session.print;
			local section_mt = getmetatable(def_env[section_name]);
			local section_help = section_mt and section_mt.help;

			local c = 0;

			if section_help then
				print("Help: "..section_name);
				if section_help.desc then
					print(section_help.desc);
				end
				print(("-"):rep(#(section_help.desc or section_name)));
				print("");

				if section_help.content then
					print(section_help.content);
					print("");
				end

				for command, command_help in it.sorted_pairs(section_help.commands or {}) do
					c = c + 1;
					local args = command_help.args:pluck("name"):concat(", ");
					local desc = command_help.desc or command_help.module and ("Provided by mod_"..command_help.module) or "";
					print(("%s:%s(%s) - %s"):format(section_name, command, args, desc));
				end
			elseif help_topics[section_name] then
				local topic = help_topics[section_name];
				if type(topic.content) == "function" then
					topic.content(self, print);
				else
					print(topic.content);
				end
				print("");
				return true, "Showing help topic '"..section_name.."'";
			else
				print("Unknown topic: "..section_name);
			end
			print("");
			return true, ("%d command(s) listed"):format(c);
		end;
	end;
});

def_env.server = new_section("Uptime, version, shutting down, etc.");

function def_env.server:insane_reload()
	prosody.unlock_globals();
	dofile "prosody"
	prosody = _G.prosody;
	return true, "Server reloaded";
end

describe_command [[server:version() - Show the server's version number]]
function def_env.server:version()
	return true, tostring(prosody.version or "unknown");
end

describe_command [[server:uptime() - Show how long the server has been running]]
function def_env.server:uptime()
	local t = os.time()-prosody.start_time;
	local seconds = t%60;
	t = (t - seconds)/60;
	local minutes = t%60;
	t = (t - minutes)/60;
	local hours = t%24;
	t = (t - hours)/24;
	local days = t;
	return true, string.format("This server has been running for %d day%s, %d hour%s and %d minute%s (since %s)",
		days, (days ~= 1 and "s") or "", hours, (hours ~= 1 and "s") or "",
		minutes, (minutes ~= 1 and "s") or "", os.date("%c", prosody.start_time));
end

describe_command [[server:shutdown(reason) - Shut down the server, with an optional reason to be broadcast to all connections]]
function def_env.server:shutdown(reason, code)
	prosody.shutdown(reason, code);
	return true, "Shutdown initiated";
end

local function human(kb)
	return format_number(kb*1024, "B", "b");
end

describe_command [[server:memory() - Show details about the server's memory usage]]
function def_env.server:memory()
	if not has_pposix or not pposix.meminfo then
		return true, "Lua is using "..human(collectgarbage("count"));
	end
	local mem, lua_mem = pposix.meminfo(), collectgarbage("count");
	local print = self.session.print;
	print("Process: "..human((mem.allocated+mem.allocated_mmap)/1024));
	print("   Used: "..human(mem.used/1024).." ("..human(lua_mem).." by Lua)");
	print("   Free: "..human(mem.unused/1024).." ("..human(mem.returnable/1024).." returnable)");
	return true, "OK";
end

def_env.module = new_section("Commands to load/reload/unload modules/plugins");

local function get_hosts_set(hosts)
	if type(hosts) == "table" then
		if hosts[1] then
			return set.new(hosts);
		elseif hosts._items then
			return hosts;
		end
	elseif type(hosts) == "string" then
		return set.new { hosts };
	elseif hosts == nil then
		return set.new(array.collect(keys(prosody.hosts)));
	end
end

-- Hosts with a module or all virtualhosts if no module given
-- matching modules_enabled in the global section
local function get_hosts_with_module(hosts, module)
	local hosts_set = get_hosts_set(hosts)
	/ function (host)
			if module then
				-- Module given, filter in hosts with this module loaded
				if modulemanager.is_loaded(host, module) then
					return host;
				else
					return nil;
				end
			end
			if not hosts then
				-- No hosts given, filter in VirtualHosts
				if prosody.hosts[host].type == "local" then
					return host;
				else
					return nil
				end
			end;
			-- No module given, but hosts are, don't filter at all
			return host;
		end;
	if module and modulemanager.get_module("*", module) then
		hosts_set:add("*");
	end
	return hosts_set;
end

describe_command [[module:info(module, host) - Show information about a loaded module]]
function def_env.module:info(name, hosts)
	if not name then
		return nil, "module name expected";
	end
	local print = self.session.print;
	hosts = get_hosts_with_module(hosts, name);
	if hosts:empty() then
		return false, "mod_" .. name .. " does not appear to be loaded on the specified hosts";
	end

	local function item_name(item) return item.name; end

	local function task_timefmt(t)
		if not t then
			return "no last run time"
		elseif os.difftime(os.time(), t) < 86400 then
			return os.date("last run today at %H:%M", t);
		else
			return os.date("last run %A at %H:%M", t);
		end
	end

	local friendly_descriptions = {
		["adhoc-provider"] = "Ad-hoc commands",
		["auth-provider"] = "Authentication provider",
		["http-provider"] = "HTTP services",
		["net-provider"] = "Network service",
		["storage-provider"] = "Storage driver",
		["measure"] = "Legacy metrics",
		["metric"] = "Metrics",
		["task"] = "Periodic task",
	};
	local item_formatters = {
		["feature"] = tostring,
		["identity"] = function(ident) return ident.type .. "/" .. ident.category; end,
		["adhoc-provider"] = item_name,
		["auth-provider"] = item_name,
		["storage-provider"] = item_name,
		["http-provider"] = function(item, mod) return mod:http_url(item.name, item.default_path); end,
		["net-provider"] = function(item)
			local service_name = item.name;
			local ports_list = {};
			for _, interface, port in portmanager.get_active_services():iter(service_name, nil, nil) do
				table.insert(ports_list, "["..interface.."]:"..port);
			end
			if not ports_list[1] then
				return service_name..": not listening on any ports";
			end
			return service_name..": "..table.concat(ports_list, ", ");
		end,
		["measure"] = function(item) return item.name .. " (" .. suf(item.conf and item.conf.unit, " ") .. item.type .. ")"; end,
		["metric"] = function(item)
			return ("%s (%s%s)%s"):format(item.name, suf(item.mf.unit, " "), item.mf.type_, pre(": ", item.mf.description));
		end,
		["task"] = function (item) return string.format("%s (%s, %s)", item.name or item.id, item.when, task_timefmt(item.last)); end
	};

	for host in hosts do
		local mod = modulemanager.get_module(host, name);
		if mod.module.host == "*" then
			print("in global context");
		else
			print("on " .. tostring(prosody.hosts[mod.module.host]));
		end
		print("  path: " .. (mod.module.path or "n/a"));
		if mod.module.status_message then
			print("  status: [" .. mod.module.status_type .. "] " .. mod.module.status_message);
		end
		if mod.module.items and next(mod.module.items) ~= nil then
			print("  provides:");
			for kind, items in pairs(mod.module.items) do
				local label = friendly_descriptions[kind] or kind:gsub("%-", " "):gsub("^%a", string.upper);
				print(string.format("  - %s (%d item%s)", label, #items, #items > 1 and "s" or ""));
				local formatter = item_formatters[kind];
				if formatter then
					for _, item in ipairs(items) do
						print("    - " .. formatter(item, mod.module));
					end
				end
			end
		end
		if mod.module.dependencies and next(mod.module.dependencies) ~= nil then
			print("  dependencies:");
			for dep in pairs(mod.module.dependencies) do
				-- Dependencies are per module instance, not per host, so dependencies
				-- of/on global modules may list modules not actually loaded on the
				-- current host.
				if modulemanager.is_loaded(host, dep) then
					print("  - mod_" .. dep);
				end
			end
		end
		if mod.module.reverse_dependencies and next(mod.module.reverse_dependencies) ~= nil then
			print("  reverse dependencies:");
			for dep in pairs(mod.module.reverse_dependencies) do
				if modulemanager.is_loaded(host, dep) then
					print("  - mod_" .. dep);
				end
			end
		end
	end
	return true;
end

describe_command [[module:load(module, host) - Load the specified module on the specified host (or all hosts if none given)]]
function def_env.module:load(name, hosts)
	hosts = get_hosts_with_module(hosts);

	local already_loaded = set.new();
	-- Load the module for each host
	local ok, err, count, mod = true, nil, 0;
	for host in hosts do
		local configured_modules, component = modulemanager.get_modules_for_host(host);

		if (not modulemanager.is_loaded(host, name)) then
			mod, err = modulemanager.load(host, name);
			if not mod then
				ok = false;
				if err == "global-module-already-loaded" then
					if count > 0 then
						ok, err, count = true, nil, 1;
					end
					break;
				end
				self.session.print(err or "Unknown error loading module");
			else
				count = count + 1;
				self.session.print("Loaded for "..mod.module.host);

				if not (configured_modules:contains(name) or name == component) then
					self.session.print("Note: Module will not be loaded after restart unless enabled in configuration");
				end
			end
		else
			already_loaded:add(host);
		end
	end

	if not ok then
		return ok, "Last error: "..tostring(err);
	end
	if already_loaded == hosts then
		return ok, "Module already loaded";
	end
	return ok, "Module loaded onto "..count.." host"..(count ~= 1 and "s" or "");
end

describe_command [[module:unload(module, host) - The same, but just unloads the module from memory]]
function def_env.module:unload(name, hosts)
	hosts = get_hosts_with_module(hosts, name);

	-- Unload the module for each host
	local ok, err, count = true, nil, 0;
	for host in hosts do
		local configured_modules, component = modulemanager.get_modules_for_host(host);

		if modulemanager.is_loaded(host, name) then
			ok, err = modulemanager.unload(host, name);
			if not ok then
				ok = false;
				self.session.print(err or "Unknown error unloading module");
			else
				count = count + 1;
				self.session.print("Unloaded from "..host);

				if configured_modules:contains(name) or name == component then
					self.session.print("Note: Module will be loaded after restart unless disabled in configuration");
				end
			end
		end
	end
	return ok, (ok and "Module unloaded from "..count.." host"..(count ~= 1 and "s" or "")) or ("Last error: "..tostring(err));
end

local function _sort_hosts(a, b)
	if a == "*" then return true
	elseif b == "*" then return false
	else return a:gsub("[^.]+", string.reverse):reverse() < b:gsub("[^.]+", string.reverse):reverse(); end
end

describe_command [[module:reload(module, host) - The same, but unloads and loads the module (saving state if the module supports it)]]
function def_env.module:reload(name, hosts)
	hosts = array.collect(get_hosts_with_module(hosts, name)):sort(_sort_hosts)

	-- Reload the module for each host
	local ok, err, count = true, nil, 0;
	for _, host in ipairs(hosts) do
		if modulemanager.is_loaded(host, name) then
			ok, err = modulemanager.reload(host, name);
			if not ok then
				ok = false;
				self.session.print(err or "Unknown error reloading module");
			else
				count = count + 1;
				if ok == nil then
					ok = true;
				end
				self.session.print("Reloaded on "..host);
			end
		end
	end
	return ok, (ok and "Module reloaded on "..count.." host"..(count ~= 1 and "s" or "")) or ("Last error: "..tostring(err));
end

describe_command [[module:list(host) - List the modules loaded on the specified host]]
function def_env.module:list(hosts)
	hosts = array.collect(set.new({ not hosts and "*" or nil }) + get_hosts_set(hosts)):sort(_sort_hosts);

	local print = self.session.print;
	for _, host in ipairs(hosts) do
		print((host == "*" and "Global" or host)..":");
		local modules = array.collect(keys(modulemanager.get_modules(host) or {})):sort();
		if #modules == 0 then
			if prosody.hosts[host] then
				print("    No modules loaded");
			else
				print("    Host not found");
			end
		else
			for _, name in ipairs(modules) do
				local status, status_text = modulemanager.get_module(host, name).module:get_status();
				local status_summary = "";
				if status == "warn" or status == "error" then
					status_summary = (" (%s: %s)"):format(status, status_text);
				end
				print(("    %s%s"):format(name, status_summary));
			end
		end
	end
end

def_env.config = new_section("Reloading the configuration, etc.");

function def_env.config:load(filename, format)
	local config_load = require "prosody.core.configmanager".load;
	local ok, err = config_load(filename, format);
	if not ok then
		return false, err or "Unknown error loading config";
	end
	return true, "Config loaded";
end

describe_command [[config:get([host,] option) - Show the value of a config option.]]
function def_env.config:get(host, key)
	if key == nil then
		host, key = "*", host;
	end
	local config_get = require "prosody.core.configmanager".get
	return true, serialize_config(config_get(host, key));
end

describe_command [[config:set([host,] option, value) - Update the value of a config option without writing to the config file.]]
function def_env.config:set(host, key, value)
	if host ~= "*" and not prosody.hosts[host] then
		host, key, value = "*", host, key;
	end
	return require "prosody.core.configmanager".set(host, key, value);
end

describe_command [[config:reload() - Reload the server configuration. Modules may need to be reloaded for changes to take effect.]]
function def_env.config:reload()
	local ok, err = prosody.reload_config();
	return ok, (ok and "Config reloaded (you may need to reload modules to take effect)") or tostring(err);
end

def_env.c2s = new_section("Commands to manage local client-to-server sessions");

local function get_jid(session)
	if session.username then
		return session.full_jid or jid_join(session.username, session.host, session.resource);
	end

	local conn = session.conn;
	local ip = session.ip or "?";
	local clientport = conn and conn:clientport() or "?";
	local serverip = conn and conn.server and conn:server():ip() or "?";
	local serverport = conn and conn:serverport() or "?"
	return jid_join("["..ip.."]:"..clientport, session.host or "["..serverip.."]:"..serverport);
end

local function get_c2s()
	local c2s = array.collect(values(prosody.full_sessions));
	c2s:append(array.collect(values(module:shared"/*/c2s/sessions")));
	c2s:append(array.collect(values(module:shared"/*/bosh/sessions")));
	c2s:unique();
	return c2s;
end

local function _sort_by_jid(a, b)
	if a.host == b.host then
		if a.username == b.username then return (a.resource or "") > (b.resource or ""); end
		return (a.username or "") > (b.username or "");
	end
	return _sort_hosts(a.host or "", b.host or "");
end

local function show_c2s(callback)
	get_c2s():sort(_sort_by_jid):map(function (session)
		callback(get_jid(session), session)
	end);
end

describe_command [[c2s:count() - Count sessions without listing them]]
function def_env.c2s:count()
	local c2s = get_c2s();
	return true, "Total: "..  #c2s .." clients";
end

local function get_s2s_hosts(session) --> local,remote
	if session.direction == "outgoing" then
		return session.host or session.from_host, session.to_host;
	elseif session.direction == "incoming" then
		return session.host or session.to_host, session.from_host;
	end
end

available_columns = {
	jid = {
		title = "JID";
		description = "Full JID of user session";
		width = "3p";
		key = "full_jid";
		mapper = function(full_jid, session) return full_jid or get_jid(session) end;
	};
	host = {
		title = "Host";
		description = "Local hostname";
		key = "host";
		width = "1p";
		mapper = function(host, session)
			return host or get_s2s_hosts(session) or "?";
		end;
	};
	remote = {
		title = "Remote";
		description = "Remote hostname";
		width = "1p";
		mapper = function(_, session)
			return select(2, get_s2s_hosts(session));
		end;
	};
	port = {
		title = "Port";
		description = "Server port used";
		width = #string.format("%d", 0xffff); -- max 16 bit unsigned integer
		align = "right";
		key = "conn";
		mapper = function(conn)
			if conn then
				return conn:serverport();
			end
		end;
	};
	created = {
		title = "Connection Created";
		description = "Time when connection was created";
		width = #"YYYY MM DD HH:MM:SS";
		align = "right";
		key = "conn";
		mapper = function(conn)
			if conn then
				return os.date("%F %T", math.floor(conn.created));
			end
		end;
	};
	dir = {
		title = "Dir";
		description = "Direction of server-to-server connection";
		width = #"<->";
		key = "direction";
		mapper = function(dir, session)
			if session.incoming and session.outgoing then return "<->"; end
			if dir == "outgoing" then return "-->"; end
			if dir == "incoming" then return "<--"; end
		end;
	};
	id = {
		title = "Session ID";
		description = "Internal session ID used in logging";
		-- Depends on log16(?) of pointers which may vary over runtime, so + some margin
		width = math.max(#"c2s", #"s2sin", #"s2sout") + #(tostring({}):match("%x+$")) + 2;
		key = "id";
	};
	type = {
		title = "Type";
		description = "Session type";
		width = math.max(#"c2s_unauthed", #"s2sout_unauthed");
		key = "type";
	};
	method = {
		title = "Method";
		description = "Connection method";
		width = math.max(#"BOSH", #"WebSocket", #"TCP");
		mapper = function(_, session)
			if session.bosh_version then
				return "BOSH";
			elseif session.websocket_request then
				return "WebSocket";
			else
				return "TCP";
			end
		end;
	};
	ipv = {
		title = "IPv";
		description = "Internet Protocol version (4 or 6)";
		width = #"IPvX";
		key = "ip";
		mapper = function(ip) if ip then return ip:find(":") and "IPv6" or "IPv4"; end end;
	};
	ip = {
		title = "IP address";
		description = "IP address the session connected from";
		width = module:get_option_boolean("use_ipv6", true) and #"ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff" or #"198.051.100.255";
		key = "ip";
	};
	status = {
		title = "Status";
		description = "Presence status";
		width = math.max(#"online", #"chat");
		key = "presence";
		mapper = function(p)
			if not p then return ""; end
			return p:get_child_text("show") or "online";
		end;
	};
	secure = {
		title = "Security";
		description = "TLS version or security status";
		key = "conn";
		width = math.max(#"secure", #"TLSvX.Y");
		mapper = function(conn, session)
			if not session.secure then return "insecure"; end
			if not conn or not conn:ssl() then return "secure" end
			local tls_info = conn.ssl_info and conn:ssl_info();
			return tls_info and tls_info.protocol or "secure";
		end;
	};
	encryption = {
		title = "Encryption";
		description = "Encryption algorithm used (TLS cipher suite)";
		-- openssl ciphers 'ALL:COMPLEMENTOFALL' | tr : \\n | awk 'BEGIN {n=1} length() > n {n=length()} END {print(n)}'
		width = #"ECDHE-ECDSA-CHACHA20-POLY1305";
		key = "conn";
		mapper = function(conn)
			local info = conn and conn.ssl_info and conn:ssl_info();
			if info then return info.cipher end
		end;
	};
	cert = {
		title = "Certificate";
		description = "Validation status of certificate";
		key = "cert_identity_status";
		width = math.max(#"Expired", #"Self-signed", #"Untrusted", #"Mismatched", #"Unknown");
		mapper = function(cert_status, session)
			if cert_status == "invalid" then
				-- non-nil cert_identity_status implies valid chain, which covers just
				-- about every error condition except mismatched certificate names
				return "Mismatched";
			elseif cert_status then
				-- basically only "valid"
				return capitalize(cert_status);
			end
			-- no certificate status,
			if type(session.cert_chain_errors) == "table" then
				local cert_errors = set.new(session.cert_chain_errors[1]);
				if cert_errors:contains("certificate has expired") then
					return "Expired";
				elseif cert_errors:contains("self signed certificate") then
					return "Self-signed";
				end
				-- Some other cert issue, or something up the chain
				-- TODO borrow more logic from mod_s2s/friendly_cert_error()
				return "Untrusted";
			end
			-- TODO cert_chain_errors can be a string, handle that
			return "Unknown";
		end;
	};
	sni = {
		title = "SNI";
		description = "Hostname requested in TLS";
		width = "1p"; -- same as host, remote etc
		mapper = function(_, session)
			if not session.conn then return end
			local sock = session.conn:socket();
			return sock and sock.getsniname and sock:getsniname() or "";
		end;
	};
	alpn = {
		title = "ALPN";
		description = "Protocol requested in TLS";
		width = math.max(#"http/1.1", #"xmpp-client", #"xmpp-server");
		mapper = function(_, session)
			if not session.conn then return end
			local sock = session.conn:socket();
			return sock and sock.getalpn and sock:getalpn() or "";
		end;
	};
	smacks = {
		title = "SM";
		description = "Stream Management (XEP-0198) status";
		key = "smacks";
		-- FIXME shorter synonym for hibernating
		width = math.max(#"yes", #"no", #"hibernating");
		mapper = function(smacks_xmlns, session)
			if not smacks_xmlns then return "no"; end
			if session.hibernating then return "hibernating"; end
			return "yes";
		end;
	};
	smacks_queue = {
		title = "SM Queue";
		description = "Length of Stream Management stanza queue";
		key = "outgoing_stanza_queue";
		width = 8;
		align = "right";
		mapper = function (queue)
			return queue and tostring(queue:count_unacked());
		end
	};
	csi = {
		title = "CSI State";
		description = "Client State Indication (XEP-0352)";
		key = "state";
		-- TODO include counter
	};
	s2s_sasl = {
		title = "SASL";
		description = "Server authentication status";
		key = "external_auth";
		width = 10;
		mapper = capitalize
	};
	dialback = {
		title = "Dialback";
		description = "Legacy server verification";
		key = "dialback_key";
		width = math.max(#"Not used", #"Not initiated", #"Initiated", #"Completed");
		mapper = function (dialback_key, session)
			if not dialback_key then
				if session.type == "s2sin" or session.type == "s2sout" then
					return "Not used";
				end
				return "Not initiated";
			elseif session.type == "s2sin_unauthed" or session.type == "s2sout_unauthed" then
				return "Initiated";
			else
				return "Completed";
			end
		end
	};
	role = {
		title = "Role";
		description = "Session role with 'prosody:' prefix removed";
		width = "1p";
		key = "role";
		mapper = function(role)
			local name = role and role.name;
			return name and name:match"^prosody:(%w+)" or name;
		end;
	}
};

local function get_colspec(colspec, default)
	if type(colspec) == "string" then colspec = array(colspec:gmatch("%S+")); end
	local columns = {};
	for i, col in pairs(colspec or default) do
		if type(col) == "string" then
			columns[i] = available_columns[col] or { title = capitalize(col); width = "1p"; key = col };
		elseif type(col) ~= "table" then
			return false, ("argument %d: expected string|table but got %s"):format(i, type(col));
		else
			columns[i] = col;
		end
	end

	return columns;
end

describe_command [[c2s:show(jid, columns) - Show all client sessions with the specified JID (or all if no JID given)]]
function def_env.c2s:show(match_jid, colspec)
	local print = self.session.print;
	local columns = get_colspec(colspec, { "id"; "jid"; "role"; "ipv"; "status"; "secure"; "smacks"; "csi" });
	local row = format_table(columns, self.session.width);

	local function match(session)
		local jid = get_jid(session)
		return (not match_jid) or match_jid == "*" or jid_compare(jid, match_jid);
	end

	local group_by_host = true;
	for _, col in ipairs(columns) do
		if col.key == "full_jid" or col.key == "host" then
			group_by_host = false;
			break
		end
	end

	if not group_by_host then print(row()); end
	local currenthost = nil;

	local c2s_sessions = get_c2s();
	local total_count = #c2s_sessions;
	c2s_sessions:filter(match):sort(_sort_by_jid);
	local shown_count = #c2s_sessions;
	for _, session in ipairs(c2s_sessions) do
		if group_by_host and session.host ~= currenthost then
			currenthost = session.host;
			print("#",prosody.hosts[currenthost] or "Unknown host");
			print(row());
		end

		print(row(session));
	end
	if total_count ~= shown_count then
		return true, ("%d out of %d c2s sessions shown"):format(shown_count, total_count);
	end
	return true, ("%d c2s sessions shown"):format(total_count);
end

describe_command [[c2s:show_tls(jid) - Show TLS cipher info for encrypted sessions]]
function def_env.c2s:show_tls(match_jid)
	return self:show(match_jid, { "jid"; "id"; "secure"; "encryption" });
end

local function build_reason(text, condition)
	if text or condition then
		return {
			text = text,
			condition = condition or "undefined-condition",
		};
	end
end

describe_command [[c2s:close(jid) - Close all sessions for the specified JID]]
function def_env.c2s:close(match_jid, text, condition)
	local count = 0;
	show_c2s(function (jid, session)
		if jid == match_jid or jid_bare(jid) == match_jid then
			count = count + 1;
			session:close(build_reason(text, condition));
		end
	end);
	return true, "Total: "..count.." sessions closed";
end

describe_command [[c2s:closeall() - Close all active c2s connections ]]
function def_env.c2s:closeall(text, condition)
	local count = 0;
	--luacheck: ignore 212/jid
	show_c2s(function (jid, session)
		count = count + 1;
		session:close(build_reason(text, condition));
	end);
	return true, "Total: "..count.." sessions closed";
end


def_env.s2s = new_section("Commands to manage sessions between this server and others");

local function _sort_s2s(a, b)
	local a_local, a_remote = get_s2s_hosts(a);
	local b_local, b_remote = get_s2s_hosts(b);
	if (a_local or "") == (b_local or "") then return _sort_hosts(a_remote or "", b_remote or ""); end
	return _sort_hosts(a_local or "", b_local or "");
end

local function match_wildcard(match_jid, jid)
	-- host == host or (host) == *.(host) or sub(.host) == *(.host)
	return jid == match_jid or jid == match_jid:sub(3) or jid:sub(-#match_jid + 1) == match_jid:sub(2);
end

local function match_s2s_jid(session, match_jid)
	local host, remote = get_s2s_hosts(session);
	if not match_jid or match_jid == "*" then
		return true;
	elseif host == match_jid or remote == match_jid then
		return true;
	elseif match_jid:sub(1, 2) == "*." then
		return match_wildcard(match_jid, host) or match_wildcard(match_jid, remote);
	end
	return false;
end

describe_command [[s2s:show(domain, columns) - Show all s2s connections for the given domain (or all if no domain given)]]
function def_env.s2s:show(match_jid, colspec)
	local print = self.session.print;
	local columns = get_colspec(colspec, { "id"; "host"; "dir"; "remote"; "ipv"; "secure"; "s2s_sasl"; "dialback" });
	local row = format_table(columns, self.session.width);

	local function match(session)
		return match_s2s_jid(session, match_jid);
	end

	local group_by_host = true;
	local currenthost = nil;
	for _, col in ipairs(columns) do
		if col.key == "host" then
			group_by_host = false;
			break
		end
	end

	if not group_by_host then print(row()); end

	local s2s_sessions = array(iterators.values(module:shared"/*/s2s/sessions"));
	local total_count = #s2s_sessions;
	s2s_sessions:filter(match):sort(_sort_s2s);
	local shown_count = #s2s_sessions;

	for _, session in ipairs(s2s_sessions) do
		if group_by_host and currenthost ~= get_s2s_hosts(session) then
			currenthost = get_s2s_hosts(session);
			print("#",prosody.hosts[currenthost] or "Unknown host");
			print(row());
		end

		print(row(session));
	end
	if total_count ~= shown_count then
		return true, ("%d out of %d s2s connections shown"):format(shown_count, total_count);
	end
	return true, ("%d s2s connections shown"):format(total_count);
end

describe_command [[s2s:show_tls(domain) - Show TLS cipher info for encrypted sessions]]
function def_env.s2s:show_tls(match_jid)
	return self:show(match_jid, { "id"; "host"; "dir"; "remote"; "secure"; "encryption"; "cert" });
end

local function print_subject(print, subject)
	for _, entry in ipairs(subject) do
		print(
			("    %s: %q"):format(
				entry.name or entry.oid,
				entry.value:gsub("[\r\n%z%c]", " ")
			)
		);
	end
end

-- As much as it pains me to use the 0-based depths that OpenSSL does,
-- I think there's going to be more confusion among operators if we
-- break from that.
local function print_errors(print, errors)
	for depth, t in pairs(errors) do
		print(
			("    %d: %s"):format(
				depth-1,
				table.concat(t, "\n|        ")
			)
		);
	end
end

function def_env.s2s:showcert(domain)
	local print = self.session.print;
	local s2s_sessions = module:shared"/*/s2s/sessions";
	local domain_sessions = set.new(array.collect(values(s2s_sessions)))
		/function(session) return match_s2s_jid(session, domain) and session or nil; end;
	local cert_set = {};
	for session in domain_sessions do
		local conn = session.conn;
		conn = conn and conn:socket();
		if not conn.getpeerchain then
			if conn.dohandshake then
				error("This version of LuaSec does not support certificate viewing");
			end
		else
			local cert = conn:getpeercertificate();
			if cert then
				local certs = conn:getpeerchain();
				local digest = cert:digest("sha1");
				if not cert_set[digest] then
					local chain_valid, chain_errors = conn:getpeerverification();
					cert_set[digest] = {
						{
						  from = session.from_host,
						  to = session.to_host,
						  direction = session.direction
						};
						chain_valid = chain_valid;
						chain_errors = chain_errors;
						certs = certs;
					};
				else
					table.insert(cert_set[digest], {
						from = session.from_host,
						to = session.to_host,
						direction = session.direction
					});
				end
			end
		end
	end
	local domain_certs = array.collect(values(cert_set));
	-- Phew. We now have a array of unique certificates presented by domain.
	local n_certs = #domain_certs;

	if n_certs == 0 then
		return "No certificates found for "..domain;
	end

	local function _capitalize_and_colon(byte)
		return string.upper(byte)..":";
	end
	local function pretty_fingerprint(hash)
		return hash:gsub("..", _capitalize_and_colon):sub(1, -2);
	end

	for cert_info in values(domain_certs) do
		local certs = cert_info.certs;
		local cert = certs[1];
		print("---")
		print("Fingerprint (SHA1): "..pretty_fingerprint(cert:digest("sha1")));
		print("");
		local n_streams = #cert_info;
		print("Currently used on "..n_streams.." stream"..(n_streams==1 and "" or "s")..":");
		for _, stream in ipairs(cert_info) do
			if stream.direction == "incoming" then
				print("    "..stream.to.." <- "..stream.from);
			else
				print("    "..stream.from.." -> "..stream.to);
			end
		end
		print("");
		local chain_valid, errors = cert_info.chain_valid, cert_info.chain_errors;
		local valid_identity = cert_verify_identity(domain, "xmpp-server", cert);
		if chain_valid then
			print("Trusted certificate: Yes");
		else
			print("Trusted certificate: No");
			print_errors(print, errors);
		end
		print("");
		print("Issuer: ");
		print_subject(print, cert:issuer());
		print("");
		print("Valid for "..domain..": "..(valid_identity and "Yes" or "No"));
		print("Subject:");
		print_subject(print, cert:subject());
	end
	print("---");
	return ("Showing "..n_certs.." certificate"
		..(n_certs==1 and "" or "s")
		.." presented by "..domain..".");
end

describe_command [[s2s:close(from, to) - Close a connection from one domain to another]]
function def_env.s2s:close(from, to, text, condition)
	local print, count = self.session.print, 0;
	local s2s_sessions = module:shared"/*/s2s/sessions";

	local match_id;
	if from and not to then
		match_id, from = from, nil;
	elseif not to then
		return false, "Syntax: s2s:close('from', 'to') - Closes all s2s sessions from 'from' to 'to'";
	elseif from == to then
		return false, "Both from and to are the same... you can't do that :)";
	end

	for _, session in pairs(s2s_sessions) do
		local id = session.id or (session.type .. tostring(session):match("[a-f0-9]+$"));
		if (match_id and match_id == id) or ((from and match_wildcard(from, session.to_host)) or (to and match_wildcard(to, session.to_host))) then
			print(("Closing connection from %s to %s [%s]"):format(session.from_host, session.to_host, id));
			(session.close or s2smanager.destroy_session)(session, build_reason(text, condition));
			count = count + 1;
		end
	end
	return true, "Closed "..count.." s2s session"..((count == 1 and "") or "s");
end

describe_command [[s2s:closeall(host) - Close all the incoming/outgoing s2s sessions to specified host]]
function def_env.s2s:closeall(host, text, condition)
	local count = 0;
	local s2s_sessions = module:shared"/*/s2s/sessions";
	for _,session in pairs(s2s_sessions) do
		if not host or host == "*" or match_s2s_jid(session, host) then
			session:close(build_reason(text, condition));
			count = count + 1;
		end
	end
	if count == 0 then return false, "No sessions to close.";
	else return true, "Closed "..count.." s2s session"..((count == 1 and "") or "s"); end
end

def_env.host = new_section("Commands to activate, deactivate and list virtual hosts");

describe_command [[host:activate(hostname) - Activates the specified host]]
function def_env.host:activate(hostname, config)
	return hostmanager.activate(hostname, config);
end

describe_command [[host:deactivate(hostname) - Disconnects all clients on this host and deactivates]]
function def_env.host:deactivate(hostname, reason)
	return hostmanager.deactivate(hostname, reason);
end

describe_command [[host:list() - List the currently-activated hosts]]
function def_env.host:list()
	local print = self.session.print;
	local i = 0;
	local host_type;
	for host, host_session in iterators.sorted_pairs(prosody.hosts, _sort_hosts) do
		i = i + 1;
		host_type = host_session.type;
		if host_type == "local" then
			print(host);
		else
			host_type = module:context(host):get_option_string("component_module", host_type);
			if host_type ~= "component" then
				host_type = host_type .. " component";
			end
			print(("%s (%s)"):format(host, host_type));
		end
	end
	return true, i.." hosts";
end

def_env.port = new_section("Commands to manage ports the server is listening on");

describe_command [[port:list() - Lists all network ports prosody currently listens on]]
function def_env.port:list()
	local print = self.session.print;
	local services = portmanager.get_active_services().data;
	local n_services, n_ports = 0, 0;
	for service, interfaces in iterators.sorted_pairs(services) do
		n_services = n_services + 1;
		local ports_list = {};
		for interface, ports in pairs(interfaces) do
			for port in pairs(ports) do
				table.insert(ports_list, "["..interface.."]:"..port);
			end
		end
		n_ports = n_ports + #ports_list;
		print(service..": "..table.concat(ports_list, ", "));
	end
	return true, n_services.." services listening on "..n_ports.." ports";
end

describe_command [[port:close(port, interface) - Close a port]]
function def_env.port:close(close_port, close_interface)
	close_port = assert(tonumber(close_port), "Invalid port number");
	local n_closed = 0;
	local services = portmanager.get_active_services().data;
	for service, interfaces in pairs(services) do -- luacheck: ignore 213
		for interface, ports in pairs(interfaces) do
			if not close_interface or close_interface == interface then
				if ports[close_port] then
					self.session.print("Closing ["..interface.."]:"..close_port.."...");
					local ok, err = portmanager.close(interface, close_port)
					if not ok then
						self.session.print("Failed to close "..interface.." "..close_port..": "..err);
					else
						n_closed = n_closed + 1;
					end
				end
			end
		end
	end
	return true, "Closed "..n_closed.." ports";
end

def_env.muc = new_section("Commands to create, list and manage chat rooms");

local console_room_mt = {
	__index = function (self, k) return self.room[k]; end;
	__tostring = function (self)
		return "MUC room <"..self.room.jid..">";
	end;
};

local function check_muc(jid)
	local room_name, host = jid_split(jid);
	if not prosody.hosts[host] then
		return nil, "No such host: "..host;
	elseif not prosody.hosts[host].modules.muc then
		return nil, "Host '"..host.."' is not a MUC service";
	end
	return room_name, host;
end

local function get_muc(room_jid)
	local room_name, host = check_muc(room_jid);
	if not room_name then
		return room_name, host;
	end
	local room_obj = prosody.hosts[host].modules.muc.get_room_from_jid(room_jid);
	if not room_obj then
		return nil, "No such room: "..room_jid;
	end
	return room_obj;
end

local muc_util = module:require"muc/util";

describe_command [[muc:create(roomjid, { config }) - Create the specified MUC room with the given config]]
function def_env.muc:create(room_jid, config)
	local room_name, host = check_muc(room_jid);
	if not room_name then
		return room_name, host;
	end
	if not room_name then return nil, host end
	if config ~= nil and type(config) ~= "table" then return nil, "Config must be a table"; end
	if prosody.hosts[host].modules.muc.get_room_from_jid(room_jid) then return nil, "Room exists already" end
	return prosody.hosts[host].modules.muc.create_room(room_jid, config);
end

describe_command [[muc:room(roomjid) - Reference the specified MUC room to access MUC API methods]]
function def_env.muc:room(room_jid)
	local room_obj, err = get_muc(room_jid);
	if not room_obj then
		return room_obj, err;
	end
	return setmetatable({ room = room_obj }, console_room_mt);
end

describe_command [[muc:list(host) - List rooms on the specified MUC component]]
function def_env.muc:list(host)
	local host_session = prosody.hosts[host];
	if not host_session or not host_session.modules.muc then
		return nil, "Please supply the address of a local MUC component";
	end
	local print = self.session.print;
	local c = 0;
	for room in host_session.modules.muc.each_room() do
		print(room.jid);
		c = c + 1;
	end
	return true, c.." rooms";
end

describe_command [[muc:occupants(roomjid, filter) - List room occupants, optionally filtered on substring or role]]
function def_env.muc:occupants(room_jid, filter)
	local room_obj, err = get_muc(room_jid);
	if not room_obj then
		return room_obj, err;
	end

	local print = self.session.print;
	local row = format_table({
		{ title = "Role"; width = 12; key = "role" }; -- longest role name
		{ title = "JID"; width = "75%"; key = "bare_jid" };
		{ title = "Nickname"; width = "25%"; key = "nick"; mapper = jid_resource };
	}, self.session.width);
	local occupants = array.collect(iterators.select(2, room_obj:each_occupant()));
	local total = #occupants;
	if filter then
		occupants:filter(function(occupant)
			return occupant.role == filter or jid_resource(occupant.nick):find(filter, 1, true);
		end);
	end
	local displayed = #occupants;
	occupants:sort(function(a, b)
		if a.role ~= b.role then
			return muc_util.valid_roles[a.role] > muc_util.valid_roles[b.role];
		else
			return a.bare_jid < b.bare_jid;
		end
	end);

	if displayed == 0 then
		return true, ("%d out of %d occupant%s listed"):format(displayed, total, total ~= 1 and "s" or "")
	end

	print(row());
	for _, occupant in ipairs(occupants) do
		print(row(occupant));
	end

	if total == displayed then
		return true, ("%d occupant%s listed"):format(total, total ~= 1 and "s" or "")
	else
		return true, ("%d out of %d occupant%s listed"):format(displayed, total, total ~= 1 and "s" or "")
	end
end

describe_command [[muc:affiliations(roomjid, filter) - List affiliated members of the room, optionally filtered on substring or affiliation]]
function def_env.muc:affiliations(room_jid, filter)
	local room_obj, err = get_muc(room_jid);
	if not room_obj then
		return room_obj, err;
	end

	local print = self.session.print;
	local row = format_table({
		{ title = "Affiliation"; width = 12 }; -- longest affiliation name
		{ title = "JID"; width = "75%" };
		{ title = "Nickname"; width = "25%"; key = "reserved_nickname" };
	}, self.session.width);
	local affiliated = array();
	for affiliated_jid, affiliation, affiliation_data in room_obj:each_affiliation() do
		affiliated:push(setmetatable({ affiliation; affiliated_jid }, { __index = affiliation_data }));
	end

	local total = #affiliated;
	if filter then
		affiliated:filter(function(affiliation)
			return filter == affiliation[1] or affiliation[2]:find(filter, 1, true);
		end);
	end
	local displayed = #affiliated;
	local aff_ranking = muc_util.valid_affiliations;
	affiliated:sort(function(a, b)
		if a[1] ~= b[1] then
			return aff_ranking[a[1]] > aff_ranking[b[1]];
		else
			return a[2] < b[2];
		end
	end);

	if displayed == 0 then
		return true, ("%d out of %d affiliations%s listed"):format(displayed, total, total ~= 1 and "s" or "")
	end

	print(row());
	for _, affiliation in ipairs(affiliated) do
		print(row(affiliation));
	end


	if total == displayed then
		return true, ("%d affiliation%s listed"):format(total, total ~= 1 and "s" or "")
	else
		return true, ("%d out of %d affiliation%s listed"):format(displayed, total, total ~= 1 and "s" or "")
	end
end

local um = require"prosody.core.usermanager";

def_env.user = new_section("Commands to create and delete users, and change their passwords");

describe_command [[user:create(jid, password, role) - Create the specified user account]]
function def_env.user:create(jid, password, role)
	local username, host = jid_split(jid);
	if not prosody.hosts[host] then
		return nil, "No such host: "..host;
	elseif um.user_exists(username, host) then
		return nil, "User exists";
	end

	if not role then
		role = module:get_option_string("default_provisioned_role", "prosody:member");
	end

	return promise.resolve(password or self.session.request_input("password")):next(function (password_)
		local ok, err = um.create_user_with_role(username, password_, host, role);
		if not ok then
			return promise.reject("Could not create user: "..err);
		end
		return ("Created %s with role '%s'"):format(jid, role);
	end);
end

describe_command [[user:disable(jid) - Disable the specified user account, preventing login]]
function def_env.user:disable(jid)
	local username, host = jid_split(jid);
	if not prosody.hosts[host] then
		return nil, "No such host: "..host;
	elseif not um.user_exists(username, host) then
		return nil, "No such user";
	end
	local ok, err = um.disable_user(username, host);
	if ok then
		return true, "User disabled";
	else
		return nil, "Could not disable user: "..err;
	end
end

describe_command [[user:enable(jid) - Enable the specified user account, restoring login access]]
function def_env.user:enable(jid)
	local username, host = jid_split(jid);
	if not prosody.hosts[host] then
		return nil, "No such host: "..host;
	elseif not um.user_exists(username, host) then
		return nil, "No such user";
	end
	local ok, err = um.enable_user(username, host);
	if ok then
		return true, "User enabled";
	else
		return nil, "Could not enable user: "..err;
	end
end

describe_command [[user:delete(jid) - Permanently remove the specified user account]]
function def_env.user:delete(jid)
	local username, host = jid_split(jid);
	if not prosody.hosts[host] then
		return nil, "No such host: "..host;
	elseif not um.user_exists(username, host) then
		return nil, "No such user";
	end
	local ok, err = um.delete_user(username, host);
	if ok then
		return true, "User deleted";
	else
		return nil, "Could not delete user: "..err;
	end
end

describe_command [[user:password(jid, password) - Set the password for the specified user account]]
function def_env.user:password(jid, password)
	local username, host = jid_split(jid);
	if not prosody.hosts[host] then
		return nil, "No such host: "..host;
	elseif not um.user_exists(username, host) then
		return nil, "No such user";
	end

	return promise.resolve(password or self.session.request_input("password")):next(function (password_)
		local ok, err = um.set_password(username, password_, host, nil);
		if ok then
			return "User password changed";
		else
			return promise.reject("Could not change password for user: "..err);
		end
	end);
end

describe_command [[user:roles(jid, host) - Show current roles for an user]]
function def_env.user:role(jid, host)
	local print = self.session.print;
	local username, userhost = jid_split(jid);
	if host == nil then host = userhost; end
	if not prosody.hosts[host] then
		return nil, "No such host: "..host;
	elseif prosody.hosts[userhost] and not um.user_exists(username, userhost) then
		return nil, "No such user";
	end

	local primary_role = um.get_user_role(username, host);
	local secondary_roles = um.get_user_secondary_roles(username, host);

	print(primary_role and primary_role.name or "<none>");

	local count = primary_role and 1 or 0;
	for role_name in pairs(secondary_roles or {}) do
		count = count + 1;
		print(role_name.." (secondary)");
	end

	return true, count == 1 and "1 role" or count.." roles";
end
def_env.user.roles = def_env.user.role;

describe_command [[user:setrole(jid, host, role) - Set primary role of a user (see 'help roles')]]
-- user:setrole("someone@example.com", "example.com", "prosody:admin")
-- user:setrole("someone@example.com", "prosody:admin")
function def_env.user:setrole(jid, host, new_role)
	local username, userhost = jid_split(jid);
	if new_role == nil then host, new_role = userhost, host; end
	if not prosody.hosts[host] then
		return nil, "No such host: "..host;
	elseif prosody.hosts[userhost] and not um.user_exists(username, userhost) then
		return nil, "No such user";
	end
	if userhost == host then
		return um.set_user_role(username, userhost, new_role);
	else
		return um.set_jid_role(jid, host, new_role);
	end
end

describe_command [[user:addrole(jid, host, role) - Add a secondary role to a user]]
function def_env.user:addrole(jid, host, new_role)
	local username, userhost = jid_split(jid);
	if new_role == nil then host, new_role = userhost, host; end
	if not prosody.hosts[host] then
		return nil, "No such host: "..host;
	elseif prosody.hosts[userhost] and not um.user_exists(username, userhost) then
		return nil, "No such user";
	elseif userhost ~= host then
		return nil, "Can't add roles outside users own host"
	end
	return um.add_user_secondary_role(username, host, new_role);
end

describe_command [[user:delrole(jid, host, role) - Remove a secondary role from a user]]
function def_env.user:delrole(jid, host, role_name)
	local username, userhost = jid_split(jid);
	if role_name == nil then host, role_name = userhost, host; end
	if not prosody.hosts[host] then
		return nil, "No such host: "..host;
	elseif prosody.hosts[userhost] and not um.user_exists(username, userhost) then
		return nil, "No such user";
	elseif userhost ~= host then
		return nil, "Can't remove roles outside users own host"
	end
	return um.remove_user_secondary_role(username, host, role_name);
end

describe_command [[user:list(hostname, pattern) - List users on the specified host, optionally filtering with a pattern]]
-- TODO switch to table view, include roles
function def_env.user:list(host, pat)
	if not host then
		return nil, "No host given";
	elseif not prosody.hosts[host] then
		return nil, "No such host";
	end
	local print = self.session.print;
	local total, matches = 0, 0;
	for user in um.users(host) do
		if not pat or user:match(pat) then
			print(user.."@"..host);
			matches = matches + 1;
		end
		total = total + 1;
	end
	return true, "Showing "..(pat and (matches.." of ") or "all " )..total.." users";
end

def_env.xmpp = new_section("Commands for sending XMPP stanzas");

describe_command [[xmpp:ping(localhost, remotehost) - Sends a ping to a remote XMPP server and reports the response]]
local new_id = require "prosody.util.id".medium;
function def_env.xmpp:ping(localhost, remotehost, timeout)
	localhost = select(2, jid_split(localhost));
	remotehost = select(2, jid_split(remotehost));
	if not localhost then
		return nil, "Invalid sender hostname";
	elseif not prosody.hosts[localhost] then
		return nil, "No such local host";
	end
	if not remotehost then
		return nil, "Invalid destination hostname";
	elseif prosody.hosts[remotehost] then
		return nil, "Both hosts are local";
	end
	local iq = st.iq{ from=localhost, to=remotehost, type="get", id=new_id()}
			:tag("ping", {xmlns="urn:xmpp:ping"});
	local time_start = time.now();
	local print = self.session.print;
	local function onchange(what)
		return function(event)
			local s2s_session = event.session;
			if (s2s_session.from_host == localhost and s2s_session.to_host == remotehost)
				or (s2s_session.to_host == localhost and s2s_session.from_host == remotehost) then
				local dir = available_columns.dir.mapper(s2s_session.direction, s2s_session);
				print(("Session %s (%s%s%s) %s (%gs)"):format(s2s_session.id, localhost, dir, remotehost, what,
					time.now() - time_start));
			elseif s2s_session.type == "s2sin_unauthed" and s2s_session.to_host == nil and s2s_session.from_host == nil then
				print(("Session %s %s (%gs)"):format(s2s_session.id, what, time.now() - time_start));
			end
		end
	end
	local onconnected = onchange("connected");
	local onauthenticated = onchange("authenticated");
	local onestablished = onchange("established");
	local ondestroyed = onchange("destroyed");
	module:hook("s2s-connected", onconnected, 1);
	module:context(localhost):hook("s2s-authenticated", onauthenticated, 1);
	module:hook("s2sout-established", onestablished, 1);
	module:hook("s2sin-established", onestablished, 1);
	module:hook("s2s-destroyed", ondestroyed, 1);
	return module:context(localhost):send_iq(iq, nil, timeout):finally(function()
		module:unhook("s2s-connected", onconnected, 1);
		module:context(localhost):unhook("s2s-authenticated", onauthenticated);
		module:unhook("s2sout-established", onestablished);
		module:unhook("s2sin-established", onestablished);
		module:unhook("s2s-destroyed", ondestroyed);
	end):next(function(pong)
		return ("pong from %s on %s in %gs"):format(pong.stanza.attr.from, pong.origin.id, time.now() - time_start);
	end);
end

def_env.dns = new_section("Commands to manage and inspect the internal DNS resolver");
local adns = require"prosody.net.adns";

local function get_resolver(session)
	local resolver = session.dns_resolver;
	if not resolver then
		resolver = adns.resolver();
		session.dns_resolver = resolver;
	end
	return resolver;
end

describe_command [[dns:lookup(name, type, class) - Do a DNS lookup]]
function def_env.dns:lookup(name, typ, class)
	local resolver = get_resolver(self.session);
	return resolver:lookup_promise(name, typ, class)
end

describe_command [[dns:addnameserver(nameserver) - Add a nameserver to the list]]
function def_env.dns:addnameserver(...)
	local resolver = get_resolver(self.session);
	resolver._resolver:addnameserver(...)
	return true
end

describe_command [[dns:setnameserver(nameserver) - Replace the list of name servers with the supplied one]]
function def_env.dns:setnameserver(...)
	local resolver = get_resolver(self.session);
	resolver._resolver:setnameserver(...)
	return true
end

describe_command [[dns:purge() - Clear the DNS cache]]
function def_env.dns:purge()
	local resolver = get_resolver(self.session);
	resolver._resolver:purge()
	return true
end

describe_command [[dns:cache() - Show cached records]]
function def_env.dns:cache()
	local resolver = get_resolver(self.session);
	return true, "Cache:\n"..tostring(resolver._resolver.cache)
end

def_env.http = new_section("Commands to inspect HTTP services");

describe_command [[http:list(hosts) - Show HTTP endpoints]]
function def_env.http:list(hosts)
	local print = self.session.print;
	hosts = array.collect(set.new({ not hosts and "*" or nil }) + get_hosts_set(hosts)):sort(_sort_hosts);
	local output_simple = format_table({
		{ title = "Module"; width = "1p" };
		{ title = "External URL"; width = "6p" };
	}, self.session.width);
	local output_split = format_table({
		{ title = "Module"; width = "1p" };
		{ title = "External URL"; width = "3p" };
		{ title = "Internal URL"; width = "3p" };
	}, self.session.width);

	for _, host in ipairs(hosts) do
		local http_apps = modulemanager.get_items("http-provider", host);
		if #http_apps > 0 then
			local http_host = module:context(host):get_option_string("http_host");
			if host == "*" then
				print("Global HTTP endpoints available on all hosts:");
			else
				print("HTTP endpoints on "..host..(http_host and (" (using "..http_host.."):") or ":"));
			end
			print(output_split());
			for _, provider in ipairs(http_apps) do
				local mod = provider._provided_by;
				local external = module:context(host):http_url(provider.name, provider.default_path);
				local internal = module:context(host):http_url(provider.name, provider.default_path, "internal");
				if external==internal then internal="" end
				mod = mod and "mod_"..mod or ""
				print((internal=="" and output_simple or output_split){mod, external, internal});
			end
			print("");
		end
	end

	local default_host = module:get_option_string("http_default_host");
	if not default_host then
		print("HTTP requests to unknown hosts will return 404 Not Found");
	else
		print("HTTP requests to unknown hosts will be handled by "..default_host);
	end
	return true;
end

def_env.watch = new_section("Commands for watching live logs from the server");

describe_command [[watch:log() - Follow debug logs]]
function def_env.watch:log()
	local writing = false;
	local sink = logger.add_simple_sink(function (source, level, message)
		if writing then return; end
		writing = true;
		self.session.print(source, level, message);
		writing = false;
	end);

	while self.session.is_connected() do
		async.sleep(3);
	end
	if not logger.remove_sink(sink) then
		module:log("warn", "Unable to remove watch:log() sink");
	end
end

describe_command [[watch:stanzas(target, filter) - Watch live stanzas matching the specified target and filter]]
local stanza_watchers = module:require("mod_debug_stanzas/watcher");
function def_env.watch:stanzas(target_spec, filter_spec)
	local function handler(event_type, stanza, session)
		if stanza then
			if event_type == "sent" then
				self.session.print(("\n<!-- sent to %s -->"):format(session.id));
			elseif event_type == "received" then
				self.session.print(("\n<!-- received from %s -->"):format(session.id));
			else
				self.session.print(("\n<!-- %s (%s) -->"):format(event_type, session.id));
			end
			self.session.print(stanza);
		elseif session then
			self.session.print("\n<!-- session "..session.id.." "..event_type.." -->");
		elseif event_type then
			self.session.print("\n<!-- "..event_type.." -->");
		end
	end

	stanza_watchers.add({
		target_spec = {
			jid = target_spec;
		};
		filter_spec = filter_spec and {
			with_jid = filter_spec;
		};
	}, handler);

	while self.session.is_connected() do
		async.sleep(3);
	end

	stanza_watchers.remove(handler);
end

def_env.debug = new_section("Commands for debugging the server");

describe_command [[debug:logevents(host) - Enable logging of fired events on host]]
function def_env.debug:logevents(host)
	if host == "*" then
		helpers.log_events(prosody.events);
	elseif host == "http" then
		helpers.log_events(require "prosody.net.http.server"._events);
		return true
	else
		helpers.log_host_events(host);
	end
	return true;
end

describe_command [[debug:events(host, event) - Show registered event handlers]]
function def_env.debug:events(host, event)
	local events_obj;
	if host and host ~= "*" then
		if host == "http" then
			events_obj = require "prosody.net.http.server"._events;
		elseif not prosody.hosts[host] then
			return false, "Unknown host: "..host;
		else
			events_obj = prosody.hosts[host].events;
		end
	else
		events_obj = prosody.events;
	end
	return true, helpers.show_events(events_obj, event);
end

describe_command [[debug:timers() - Show information about scheduled timers]]
function def_env.debug:timers()
	local print = self.session.print;
	local add_task = require"prosody.util.timer".add_task;
	local h, params = add_task.h, add_task.params;
	local function normalize_time(t)
		return t;
	end
	local function format_time(t)
		return os.date("%F %T", math.floor(normalize_time(t)));
	end
	if h then
		print("-- util.timer");
	elseif server.timer then
		print("-- net.server.timer");
		h = server.timer.add_task.timers;
		normalize_time = server.timer.to_absolute_time or normalize_time;
	end
	if h then
		local timers = {};
		for i, id in ipairs(h.ids) do
			local t, cb = h.priorities[i], h.items[id];
			if not params then
				local param = cb.param;
				if param then
					cb = param.callback;
				else
					cb = cb.timer_callback or cb;
				end
			elseif params[id] then
				cb = params[id].callback or cb;
			end
			table.insert(timers, { format_time(t), cb });
		end
		table.sort(timers, function (a, b) return a[1] < b[1] end);
		for _, t in ipairs(timers) do
			print(t[1], t[2])
		end
	end
	if server.event_base then
		local count = 0;
		for _, v in pairs(debug.getregistry()) do
			if type(v) == "function" and v.callback and v.callback == add_task._on_timer then
				count = count + 1;
			end
		end
		print(count .. " libevent callbacks");
	end
	if h then
		local next_time = h:peek();
		if next_time then
			return true, ("Next event at %s (in %.6fs)"):format(format_time(next_time), normalize_time(next_time) - time.now());
		end
	end
	return true;
end

describe_command [[debug:async() - Show information about pending asynchronous tasks]]
function def_env.debug:async(runner_id)
	local print = self.session.print;
	local time_now = time.now();

	if runner_id then
		for runner, since in pairs(async.waiting_runners) do
			if runner.id == runner_id then
				print("ID        ", runner.id);
				local f = runner.func;
				if f == async.default_runner_func then
					print("Function ", tostring(runner.current_item).." (from work queue)");
				else
					print("Function ", tostring(f));
					if st.is_stanza(runner.current_item) then
						print("Stanza:")
						print("\t"..runner.current_item:indent(2):pretty_print());
					else
						print("Work item", self.session.serialize(runner.current_item, "debug"));
					end
				end

				print("Coroutine ", tostring(runner.thread).." ("..coroutine.status(runner.thread)..")");
				print("Since     ", since);
				print("Status    ", ("%s since %s (%0.2f seconds ago)"):format(runner.state, os.date("%Y-%m-%d %R:%S", math.floor(since)), time_now-since));
				print("");
				print(debug.traceback(runner.thread));
				return true, "Runner is "..runner.state;
			end
		end
		return nil, "Runner not found or is currently idle";
	end

	local row = format_table({
		{ title = "ID"; width = 12 };
		{ title = "Function"; width = "10p" };
		{ title = "Status"; width = "16" };
		{ title = "Location"; width = "10p" };
	}, self.session.width);
	print(row())

	local c = 0;
	for runner, since in pairs(async.waiting_runners) do
		c = c + 1;
		local f = runner.func;
		if f == async.default_runner_func then
			f = runner.current_item;
		end
		-- We want to fetch the location in the code that the runner yielded from,
		-- excluding util.async's wrapper code. A level of  `2` assumes that we
		-- yielded directly from a function in util.async. This is *currently* true
		-- of all util.async yields, but it's fragile.
		local location = debug.getinfo(runner.thread, 2);
		print(row {
			runner.id;
			tostring(f);
			("%s (%0.2fs)"):format(runner.state, time_now - since);
			location.short_src..(location.currentline and ":"..location.currentline or "");
		});
	end
	return true, ("%d runners pending"):format(c);
end

def_env.stats = new_section("Commands to show internal statistics");

local short_units = {
	seconds = "s",
	bytes = "B",
};

local stats_methods = {};

function stats_methods:render_single_fancy_histogram_ex(print, prefix, metric_family, metric, cumulative)
	local creation_timestamp, sum, count
	local buckets = {}
	local prev_bucket_count = 0
	for suffix, extra_labels, value in metric:iter_samples() do
		if suffix == "_created" then
			creation_timestamp = value
		elseif suffix == "_sum" then
			sum = value
		elseif suffix == "_count" then
			count = value
		elseif extra_labels then
			local bucket_threshold = extra_labels["le"]
			local bucket_count
			if cumulative then
				bucket_count = value
			else
				bucket_count = value - prev_bucket_count
				prev_bucket_count = value
			end
			if bucket_threshold == "+Inf" then
				t_insert(buckets, {threshold = 1/0, count = bucket_count})
			elseif bucket_threshold ~= nil then
				t_insert(buckets, {threshold = tonumber(bucket_threshold), count = bucket_count})
			end
		end
	end

	if #buckets == 0 or not creation_timestamp or not sum or not count then
		print("[no data or not a histogram]")
		return false
	end

	local graph_width, graph_height, wscale = #buckets, 10, 1;
	if graph_width < 8 then
		wscale = 8
	elseif graph_width < 16 then
		wscale = 4
	elseif graph_width < 32 then
		wscale = 2
	end
	local eighth_chars = "   ▁▂▃▄▅▆▇█";

	local max_bin_samples = 0
	for _, bucket in ipairs(buckets) do
		if bucket.count > max_bin_samples then
			max_bin_samples = bucket.count
		end
	end

	print("");
	print(prefix)
	print(("_"):rep(graph_width*wscale).." "..max_bin_samples);
	for row = graph_height, 1, -1 do
		local row_chars = {};
		local min_eighths, max_eighths = 8, 0;
		for i = 1, #buckets do
			local char_eighths = math.ceil(math.max(math.min((graph_height/(max_bin_samples/buckets[i].count))-(row-1), 1), 0)*8);
			if char_eighths < min_eighths then
				min_eighths = char_eighths;
			end
			if char_eighths > max_eighths then
				max_eighths = char_eighths;
			end
			if char_eighths == 0 then
				row_chars[i] = ("-"):rep(wscale);
			else
				local char = eighth_chars:sub(char_eighths*3+1, char_eighths*3+3);
				row_chars[i] = char:rep(wscale);
			end
		end
		print(table.concat(row_chars).."|- "..string.format("%.8g", math.ceil((max_bin_samples/graph_height)*(row-0.5))));
	end

	local legend_pat = string.format("%%%d.%dg", wscale-1, wscale-1)
	local row = {}
	for i = 1, #buckets do
		local threshold = buckets[i].threshold
		t_insert(row, legend_pat:format(threshold))
	end
	t_insert(row, " " .. metric_family.unit)
	print(t_concat(row, "/"))

	return true
end

function stats_methods:render_single_fancy_histogram(print, prefix, metric_family, metric)
	return self:render_single_fancy_histogram_ex(print, prefix, metric_family, metric, false)
end

function stats_methods:render_single_fancy_histogram_cf(print, prefix, metric_family, metric)
	-- cf = cumulative frequency
	return self:render_single_fancy_histogram_ex(print, prefix, metric_family, metric, true)
end

function stats_methods:cfgraph()
	for _, stat_info in ipairs(self) do
		local family_name, metric_family = unpack(stat_info, 1, 2)
		local function print(s)
			table.insert(stat_info.output, s);
		end

		if not self:render_family(print, family_name, metric_family, self.render_single_fancy_histogram_cf) then
			return self
		end
	end
	return self;
end

function stats_methods:histogram()
	for _, stat_info in ipairs(self) do
		local family_name, metric_family = unpack(stat_info, 1, 2)
		local function print(s)
			table.insert(stat_info.output, s);
		end

		if not self:render_family(print, family_name, metric_family, self.render_single_fancy_histogram) then
			return self
		end
	end
	return self;
end

function stats_methods:render_single_counter(print, prefix, metric_family, metric)
	local created_timestamp, current_value
	for suffix, _, value in metric:iter_samples() do
		if suffix == "_created" then
			created_timestamp = value
		elseif suffix == "_total" then
			current_value = value
		end
	end
	if current_value and created_timestamp then
		local base_unit = short_units[metric_family.unit] or metric_family.unit
		local unit = base_unit .. "/s"
		local factor = 1
		if base_unit == "s" then
			-- be smart!
			unit = "%"
			factor = 100
		elseif base_unit == "" then
			unit = "events/s"
		end
		print(("%-50s %s"):format(prefix, format_number(factor * current_value / (self.now - created_timestamp), unit.." [avg]")));
	end
end

function stats_methods:render_single_gauge(print, prefix, metric_family, metric)
	local current_value
	for _, _, value in metric:iter_samples() do
		current_value = value
	end
	if current_value then
		local unit = short_units[metric_family.unit] or metric_family.unit
		print(("%-50s %s"):format(prefix, format_number(current_value, unit)));
	end
end

function stats_methods:render_single_summary(print, prefix, metric_family, metric)
	local sum, count
	for suffix, _, value in metric:iter_samples() do
		if suffix == "_sum" then
			sum = value
		elseif suffix == "_count" then
			count = value
		end
	end
	if sum and count then
		local unit = short_units[metric_family.unit] or metric_family.unit
		if count == 0 then
			print(("%-50s %s"):format(prefix, "no obs."));
		else
			print(("%-50s %s"):format(prefix, format_number(sum / count, unit.."/event [avg]")));
		end
	end
end

function stats_methods:render_family(print, family_name, metric_family, render_func)
	local labelkeys = metric_family.label_keys
	if #labelkeys > 0 then
		print(family_name)
		for labelset, metric in metric_family:iter_metrics() do
			local labels = {}
			for i, k in ipairs(labelkeys) do
				local v = labelset[i]
				t_insert(labels, ("%s=%s"):format(k, v))
			end
			local prefix = "  "..t_concat(labels, " ")
			render_func(self, print, prefix, metric_family, metric)
		end
	else
		for _, metric in metric_family:iter_metrics() do
			render_func(self, print, family_name, metric_family, metric)
		end
	end
end

local function stats_tostring(stats)
	local print = stats.session.print;
	for _, stat_info in ipairs(stats) do
		if #stat_info.output > 0 then
			print("\n#"..stat_info[1]);
			print("");
			for _, v in ipairs(stat_info.output) do
				print(v);
			end
			print("");
		else
			local metric_family = stat_info[2]
			if metric_family.type_ == "counter" then
				stats:render_family(print, stat_info[1], metric_family, stats.render_single_counter)
			elseif metric_family.type_ == "gauge" or metric_family.type_ == "unknown" then
				stats:render_family(print, stat_info[1], metric_family, stats.render_single_gauge)
			elseif metric_family.type_ == "summary" or metric_family.type_ == "histogram" then
				stats:render_family(print, stat_info[1], metric_family, stats.render_single_summary)
			end
		end
	end
	return #stats.." statistics displayed";
end

local stats_mt = {__index = stats_methods, __tostring = stats_tostring }
local function new_stats_context(self)
	-- TODO: instead of now(), it might be better to take the time of the last
	-- interval, if the statistics backend is set to use periodic collection
	-- Otherwise we get strange stuff like average cpu usage decreasing until
	-- the next sample and so on.
	return setmetatable({ session = self.session, stats = true, now = time.now() }, stats_mt);
end

describe_command [[stats:show(pattern) - Show internal statistics, optionally filtering by name with a pattern.]]
-- Undocumented currently, you can append :histogram() or :cfgraph() to stats:show() for rendered graphs.
function def_env.stats:show(name_filter)
	local statsman = require "prosody.core.statsmanager"
	local metric_registry = statsman.get_metric_registry();
	if not metric_registry then
		return nil, [[Statistics disabled. Try `statistics = "internal"` in the global section of the config file and restart.]];
	end
	local collect = statsman.collect
	if collect then
		-- force collection if in manual mode
		collect()
	end
	local displayed_stats = new_stats_context(self);
	for family_name, metric_family in iterators.sorted_pairs(metric_registry:get_metric_families()) do
		if not name_filter or family_name:match(name_filter) then
			table.insert(displayed_stats, {
				family_name,
				metric_family,
				output = {}
			})
		end
	end
	return displayed_stats;
end

local command_metadata_schema = {
	type = "object";
	properties = {
		section = { type = "string" };
		section_desc = { type = "string" };

		name = { type = "string" };
		desc = { type = "string" };
		help = { type = "string" };
		args = {
			type = "array";
			items = {
				type = "object";
				properties = {
					name = { type = "string", required = true };
					type = { type = "string", required = false };
				};
			};
		};
	};

	required = { "name", "section", "desc", "args" };
};

-- host_commands[section..":"..name][host] = handler
-- host_commands[section..":"..name][false] = metadata
local host_commands = {};

local function new_item_handlers(command_host)
	local function on_command_added(event)
		local command = event.item;
		local mod_name = event.source and ("mod_"..event.source.name) or "<unknown module>";
		if not schema.validate(command_metadata_schema, command) or type(command.handler) ~= "function" then
			module:log("warn", "Ignoring command added by %s: missing or invalid data", mod_name);
			return;
		end

		local handler = command.handler;

		if command_host then
			if type(command.host_selector) ~= "string" then
				module:log("warn", "Ignoring command %s:%s() added by %s - missing/invalid host_selector", command.section, command.name, mod_name);
				return;
			end
			local qualified_name = command.section..":"..command.name;
			local host_command_info = host_commands[qualified_name];
			if not host_command_info then
				local selector_index;
				for i, arg in ipairs(command.args) do
					if arg.name == command.host_selector then
						selector_index = i + 1; -- +1 to account for 'self'
						break;
					end
				end
				if not selector_index then
					module:log("warn", "Command %s() host selector argument '%s' not found - not registering", qualified_name, command.host_selector);
					return;
				end
				host_command_info = {
					[false] = {
						host_selector = command.host_selector;
						handler = function (...)
							local selected_host = select(2, jid_split((select(selector_index, ...))));
							if type(selected_host) ~= "string" then
								return nil, "Invalid or missing argument '"..command.host_selector.."'";
							end
							if not prosody.hosts[selected_host] then
								return nil, "Unknown host: "..selected_host;
							end
							local host_handler = host_commands[qualified_name][selected_host];
							if not host_handler then
								return nil, "This command is not available on "..selected_host;
							end
							return host_handler(...);
						end;
					};
				};
				host_commands[qualified_name] = host_command_info;
			end
			if host_command_info[command_host] then
				module:log("warn", "Command %s() is already registered - overwriting with %s", qualified_name, mod_name);
			end
			host_command_info[command_host] = handler;
		end

		local section_t = def_env[command.section];
		if not section_t then
			section_t = {};
			def_env[command.section] = section_t;
		end

		if command_host then
			section_t[command.name] = host_commands[command.section..":"..command.name][false].handler;
		else
			section_t[command.name] = command.handler;
		end

		local section_mt = getmetatable(section_t);
		if not section_mt then
			section_mt = {};
			setmetatable(section_t, section_mt);
		end
		local section_help = section_mt.help;
		if not section_help then
			section_help = {
				desc = command.section_desc;
				commands = {};
			};
			section_mt.help = section_help;
		end

		section_help.commands[command.name] = {
			desc = command.desc;
			full = command.help;
			args = array(command.args);
			module = command._provided_by;
		};

		module:log("debug", "Shell command added by %s: %s:%s()", mod_name, command.section, command.name);
	end

	local function on_command_removed(event)
		local command = event.item;

		local handler = event.item.handler;
		if type(handler) ~= "function" or not schema.validate(command_metadata_schema, command) then
			return;
		end

		local section_t = def_env[command.section];
		if not section_t or section_t[command.name] ~= handler then
			return;
		end

		section_t[command.name] = nil;
		if next(section_t) == nil then -- Delete section if empty
			def_env[command.section] = nil;
		end

		if command_host then
			local host_command_info = host_commands[command.section..":"..command.name];
			if host_command_info then
				-- Remove our host handler
				host_command_info[command_host] = nil;
				-- Clean up entire command entry if there are no per-host handlers left
				local any_hosts = false;
				for k in pairs(host_command_info) do
					if k then -- metadata is false, ignore it
						any_hosts = true;
						break;
					end
				end
				if not any_hosts then
					host_commands[command.section..":"..command.name] = nil;
				end
			end
		end
	end
	return on_command_added, on_command_removed;
end

module:handle_items("shell-command", new_item_handlers());

function module.add_host(host_module)
	host_module:handle_items("shell-command", new_item_handlers(host_module.host));
end

function module.unload()
	stanza_watchers.cleanup();
end


-------------

function printbanner(session)
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
