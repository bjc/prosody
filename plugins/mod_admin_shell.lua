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

local hostmanager = require "core.hostmanager";
local modulemanager = require "core.modulemanager";
local s2smanager = require "core.s2smanager";
local portmanager = require "core.portmanager";
local helpers = require "util.helpers";
local server = require "net.server";
local st = require "util.stanza";

local _G = _G;

local prosody = _G.prosody;

local unpack = table.unpack or unpack; -- luacheck: ignore 113
local iterators = require "util.iterators";
local keys, values = iterators.keys, iterators.values;
local jid_bare, jid_split, jid_join = import("util.jid", "bare", "prepped_split", "join");
local set, array = require "util.set", require "util.array";
local cert_verify_identity = require "util.x509".verify_identity;
local envload = require "util.envload".envload;
local envloadfile = require "util.envload".envloadfile;
local has_pposix, pposix = pcall(require, "util.pposix");
local async = require "util.async";
local serialization = require "util.serialization";
local serialize_config = serialization.new ({ fatal = false, unquoted = true});
local time = require "util.time";
local promise = require "util.promise";

local t_insert = table.insert;
local t_concat = table.concat;

local format_number = require "util.human.units".format;
local format_table = require "util.human.io".table;

local function capitalize(s)
	if not s then return end
	return (s:gsub("^%a", string.upper):gsub("_", " "));
end

local function pre(prefix, str, alt)
	if (str or "") == "" then return alt or ""; end
	return prefix .. str;
end

local function suf(str, suffix, alt)
	if (str or "") == "" then return alt or ""; end
	return str .. suffix;
end

local commands = module:shared("commands")
local def_env = module:shared("env");
local default_env_mt = { __index = def_env };

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

local function send_repl_output(session, line)
	return session.send(st.stanza("repl-output"):text(tostring(line)));
end

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
		serialize = tostring;
		disconnect = function () admin_session:close(); end;
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
	local line = event.stanza:get_text();
	local useglobalenv;

	local result = st.stanza("repl-result");

	if line:match("^>") then
		line = line:gsub("^>", "");
		useglobalenv = true;
	else
		local command = line:match("^%w+") or line:match("%p");
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

	local taskok, message = chunk();

	if promise.is_promise(taskok) then
		taskok, message = async.wait_for(taskok);
	end

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

module:hook("admin/repl-input", function (event)
	local ok, err = pcall(handle_line, event);
	if not ok then
		event.origin.send(st.stanza("repl-result", { type = "error" }):text(err));
	end
end);

-- Console commands --
-- These are simple commands, not valid standalone in Lua

local available_columns; --forward declaration so it is reachable from the help

function commands.help(session, data)
	local print = session.print;
	local section = data:match("^help (%w+)");
	if not section then
		print [[Commands are divided into multiple sections. For help on a particular section, ]]
		print [[type: help SECTION (for example, 'help c2s'). Sections are: ]]
		print [[]]
		print [[c2s - Commands to manage local client-to-server sessions]]
		print [[s2s - Commands to manage sessions between this server and others]]
		print [[http - Commands to inspect HTTP services]] -- XXX plural but there is only one so far
		print [[module - Commands to load/reload/unload modules/plugins]]
		print [[host - Commands to activate, deactivate and list virtual hosts]]
		print [[user - Commands to create and delete users, and change their passwords]]
		print [[roles - Show information about user roles]]
		print [[muc - Commands to create, list and manage chat rooms]]
		print [[stats - Commands to show internal statistics]]
		print [[server - Uptime, version, shutting down, etc.]]
		print [[port - Commands to manage ports the server is listening on]]
		print [[dns - Commands to manage and inspect the internal DNS resolver]]
		print [[xmpp - Commands for sending XMPP stanzas]]
		print [[debug - Commands for debugging the server]]
		print [[config - Reloading the configuration, etc.]]
		print [[columns - Information about customizing session listings]]
		print [[console - Help regarding the console itself]]
	elseif section == "c2s" then
		print [[c2s:show(jid, columns) - Show all client sessions with the specified JID (or all if no JID given)]]
		print [[c2s:show_tls(jid) - Show TLS cipher info for encrypted sessions]]
		print [[c2s:count() - Count sessions without listing them]]
		print [[c2s:close(jid) - Close all sessions for the specified JID]]
		print [[c2s:closeall() - Close all active c2s connections ]]
	elseif section == "s2s" then
		print [[s2s:show(domain, columns) - Show all s2s connections for the given domain (or all if no domain given)]]
		print [[s2s:show_tls(domain) - Show TLS cipher info for encrypted sessions]]
		print [[s2s:close(from, to) - Close a connection from one domain to another]]
		print [[s2s:closeall(host) - Close all the incoming/outgoing s2s sessions to specified host]]
	elseif section == "http" then
		print [[http:list(hosts) - Show HTTP endpoints]]
	elseif section == "module" then
		print [[module:info(module, host) - Show information about a loaded module]]
		print [[module:load(module, host) - Load the specified module on the specified host (or all hosts if none given)]]
		print [[module:reload(module, host) - The same, but unloads and loads the module (saving state if the module supports it)]]
		print [[module:unload(module, host) - The same, but just unloads the module from memory]]
		print [[module:list(host) - List the modules loaded on the specified host]]
	elseif section == "host" then
		print [[host:activate(hostname) - Activates the specified host]]
		print [[host:deactivate(hostname) - Disconnects all clients on this host and deactivates]]
		print [[host:list() - List the currently-activated hosts]]
	elseif section == "user" then
		print [[user:create(jid, password, roles) - Create the specified user account]]
		print [[user:password(jid, password) - Set the password for the specified user account]]
		print [[user:showroles(jid, host) - Show current roles for an user]]
		print [[user:roles(jid, host, roles) - Set roles for an user (see 'help roles')]]
		print [[user:delete(jid) - Permanently remove the specified user account]]
		print [[user:list(hostname, pattern) - List users on the specified host, optionally filtering with a pattern]]
	elseif section == "roles" then
		print [[Roles may grant access or restrict users from certain operations]]
		print [[Built-in roles are:]]
		print [[  prosody:admin - Administrator]]
		print [[  (empty set) - Normal user]]
		print [[]]
		print [[The canonical role format looks like: { ["example:role"] = true }]]
		print [[For convenience, the following formats are also accepted:]]
		print [["admin" - short for "prosody:admin", the normal admin status (like the admins config option)]]
		print [["example:role" - short for {["example:role"]=true}]]
		print [[{"example:role"} - short for {["example:role"]=true}]]
	elseif section == "muc" then
		-- TODO `muc:room():foo()` commands
		print [[muc:create(roomjid, { config }) - Create the specified MUC room with the given config]]
		print [[muc:list(host) - List rooms on the specified MUC component]]
		print [[muc:room(roomjid) - Reference the specified MUC room to access MUC API methods]]
	elseif section == "server" then
		print [[server:version() - Show the server's version number]]
		print [[server:uptime() - Show how long the server has been running]]
		print [[server:memory() - Show details about the server's memory usage]]
		print [[server:shutdown(reason) - Shut down the server, with an optional reason to be broadcast to all connections]]
	elseif section == "port" then
		print [[port:list() - Lists all network ports prosody currently listens on]]
		print [[port:close(port, interface) - Close a port]]
	elseif section == "dns" then
		print [[dns:lookup(name, type, class) - Do a DNS lookup]]
		print [[dns:addnameserver(nameserver) - Add a nameserver to the list]]
		print [[dns:setnameserver(nameserver) - Replace the list of name servers with the supplied one]]
		print [[dns:purge() - Clear the DNS cache]]
		print [[dns:cache() - Show cached records]]
	elseif section == "xmpp" then
		print [[xmpp:ping(localhost, remotehost) -- Sends a ping to a remote XMPP server and reports the response]]
	elseif section == "config" then
		print [[config:reload() - Reload the server configuration. Modules may need to be reloaded for changes to take effect.]]
		print [[config:get([host,] option) - Show the value of a config option.]]
	elseif section == "stats" then -- luacheck: ignore 542
		print [[stats:show(pattern) - Show internal statistics, optionally filtering by name with a pattern]]
		print [[stats:show():cfgraph() - Show a cumulative frequency graph]]
		print [[stats:show():histogram() - Show a histogram of selected metric]]
	elseif section == "debug" then
		print [[debug:logevents(host) - Enable logging of fired events on host]]
		print [[debug:events(host, event) - Show registered event handlers]]
		print [[debug:timers() - Show information about scheduled timers]]
	elseif section == "console" then
		print [[Hey! Welcome to Prosody's admin console.]]
		print [[First thing, if you're ever wondering how to get out, simply type 'quit'.]]
		print [[Secondly, note that we don't support the full telnet protocol yet (it's coming)]]
		print [[so you may have trouble using the arrow keys, etc. depending on your system.]]
		print [[]]
		print [[For now we offer a couple of handy shortcuts:]]
		print [[!! - Repeat the last command]]
		print [[!old!new! - repeat the last command, but with 'old' replaced by 'new']]
		print [[]]
		print [[For those well-versed in Prosody's internals, or taking instruction from those who are,]]
		print [[you can prefix a command with > to escape the console sandbox, and access everything in]]
		print [[the running server. Great fun, but be careful not to break anything :)]]
	elseif section == "columns" then
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
		local row = format_table(meta_columns, 120)
		print(row());
		for column, spec in iterators.sorted_pairs(available_columns) do
			print(row({ column, spec.title, spec.description }));
		end
		print [[]]
		print [[Most fields on the internal session structures can also be used as columns]]
		-- Also, you can pass a table column specification directly, with mapper callback and all
	end
end

-- Session environment --
-- Anything in def_env will be accessible within the session as a global variable

--luacheck: ignore 212/self
local serialize_defaults = module:get_option("console_prettyprint_settings",
	{ fatal = false; unquoted = true; maxdepth = 2; table_iterator = "pairs" })

def_env.output = {};
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

def_env.server = {};

function def_env.server:insane_reload()
	prosody.unlock_globals();
	dofile "prosody"
	prosody = _G.prosody;
	return true, "Server reloaded";
end

function def_env.server:version()
	return true, tostring(prosody.version or "unknown");
end

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

function def_env.server:shutdown(reason, code)
	prosody.shutdown(reason, code);
	return true, "Shutdown initiated";
end

local function human(kb)
	return format_number(kb*1024, "B", "b");
end

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

def_env.module = {};

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
		["net-provider"] = item_name,
		["measure"] = function(item) return item.name .. " (" .. suf(item.conf and item.conf.unit, " ") .. item.type .. ")"; end,
		["metric"] = function(item)
			return ("%s (%s%s)%s"):format(item.name, suf(item.mf.unit, " "), item.mf.type_, pre(": ", item.mf.description));
		end,
		["task"] = function (item) return string.format("%s (%s)", item.name or item.id, item.when); end
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
				print("  - mod_" .. dep);
			end
		end
	end
	return true;
end

function def_env.module:load(name, hosts, config)
	hosts = get_hosts_with_module(hosts);

	-- Load the module for each host
	local ok, err, count, mod = true, nil, 0;
	for host in hosts do
		if (not modulemanager.is_loaded(host, name)) then
			mod, err = modulemanager.load(host, name, config);
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
			end
		end
	end

	return ok, (ok and "Module loaded onto "..count.." host"..(count ~= 1 and "s" or "")) or ("Last error: "..tostring(err));
end

function def_env.module:unload(name, hosts)
	hosts = get_hosts_with_module(hosts, name);

	-- Unload the module for each host
	local ok, err, count = true, nil, 0;
	for host in hosts do
		if modulemanager.is_loaded(host, name) then
			ok, err = modulemanager.unload(host, name);
			if not ok then
				ok = false;
				self.session.print(err or "Unknown error unloading module");
			else
				count = count + 1;
				self.session.print("Unloaded from "..host);
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

def_env.config = {};
function def_env.config:load(filename, format)
	local config_load = require "core.configmanager".load;
	local ok, err = config_load(filename, format);
	if not ok then
		return false, err or "Unknown error loading config";
	end
	return true, "Config loaded";
end

function def_env.config:get(host, key)
	if key == nil then
		host, key = "*", host;
	end
	local config_get = require "core.configmanager".get
	return true, serialize_config(config_get(host, key));
end

function def_env.config:reload()
	local ok, err = prosody.reload_config();
	return ok, (ok and "Config reloaded (you may need to reload modules to take effect)") or tostring(err);
end

def_env.c2s = {};

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
		width = 32;
		key = "full_jid";
		mapper = function(full_jid, session) return full_jid or get_jid(session) end;
	};
	host = {
		title = "Host";
		description = "Local hostname";
		key = "host";
		width = 22;
		mapper = function(host, session)
			return host or get_s2s_hosts(session) or "?";
		end;
	};
	remote = {
		title = "Remote";
		description = "Remote hostname";
		width = 22;
		mapper = function(_, session)
			return select(2, get_s2s_hosts(session));
		end;
	};
	port = {
		title = "Port";
		description = "Server port used";
		width = 5;
		align = "right";
		key = "conn";
		mapper = function(conn) return conn:serverport(); end;
	};
	dir = {
		title = "Dir";
		description = "Direction of server-to-server connection";
		width = 3;
		key = "direction";
		mapper = function(dir, session)
			if session.incoming and session.outgoing then return "<->"; end
			if dir == "outgoing" then return "-->"; end
			if dir == "incoming" then return "<--"; end
		end;
	};
	id = { title = "Session ID"; description = "Internal session ID used in logging"; width = 20; key = "id" };
	type = { title = "Type"; description = "Session type"; width = #"c2s_unauthed"; key = "type" };
	method = {
		title = "Method";
		description = "Connection method";
		width = 10;
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
		width = 4;
		key = "ip";
		mapper = function(ip) if ip then return ip:find(":") and "IPv6" or "IPv4"; end end;
	};
	ip = { title = "IP address"; description = "IP address the session connected from"; width = 40; key = "ip" };
	status = {
		title = "Status";
		description = "Presence status";
		width = 6;
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
		width = 8;
		mapper = function(conn, session)
			if not session.secure then return "insecure"; end
			if not conn or not conn:ssl() then return "secure" end
			local sock = conn and conn:socket();
			if not sock then return "secure"; end
			local tls_info = sock.info and sock:info();
			return tls_info and tls_info.protocol or "secure";
		end;
	};
	encryption = {
		title = "Encryption";
		description = "Encryption algorithm used (TLS cipher suite)";
		width = 30;
		key = "conn";
		mapper = function(conn)
			local sock = conn:socket();
			local info = sock and sock.info and sock:info();
			if info then return info.cipher end
		end;
	};
	cert = {
		title = "Certificate";
		description = "Validation status of certificate";
		key = "cert_identity_status";
		width = 11;
		mapper = function(cert_status, session)
			if cert_status then return capitalize(cert_status); end
			if session.cert_chain_status == "Invalid" then
				local cert_errors = set.new(session.cert_chain_errors[1]);
				if cert_errors:contains("certificate has expired") then
					return "Expired";
				elseif cert_errors:contains("self signed certificate") then
					return "Self-signed";
				end
				return "Untrusted";
			elseif session.cert_identity_status == "invalid" then
				return "Mismatched";
			end
			return "Unknown";
		end;
	};
	sni = {
		title = "SNI";
		description = "Hostname requested in TLS";
		width = 22;
		mapper = function(_, session)
			if not session.conn then return end
			local sock = session.conn:socket();
			return sock and sock.getsniname and sock:getsniname() or "";
		end;
	};
	alpn = {
		title = "ALPN";
		description = "Protocol requested in TLS";
		width = 11;
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
		width = 11;
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
		width = 13;
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
};

local function get_colspec(colspec, default)
	if type(colspec) == "string" then colspec = array(colspec:gmatch("%S+")); end
	local columns = {};
	for i, col in pairs(colspec or default) do
		if type(col) == "string" then
			columns[i] = available_columns[col] or { title = capitalize(col); width = 20; key = col };
		elseif type(col) ~= "table" then
			return false, ("argument %d: expected string|table but got %s"):format(i, type(col));
		else
			columns[i] = col;
		end
	end

	return columns;
end

function def_env.c2s:show(match_jid, colspec)
	local print = self.session.print;
	local columns = get_colspec(colspec, { "id"; "jid"; "ipv"; "status"; "secure"; "smacks"; "csi" });
	local row = format_table(columns, 120);

	local function match(session)
		local jid = get_jid(session)
		return (not match_jid) or jid == match_jid;
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

function def_env.c2s:closeall(text, condition)
	local count = 0;
	--luacheck: ignore 212/jid
	show_c2s(function (jid, session)
		count = count + 1;
		session:close(build_reason(text, condition));
	end);
	return true, "Total: "..count.." sessions closed";
end


def_env.s2s = {};
local function _sort_s2s(a, b)
	local a_local, a_remote = get_s2s_hosts(a);
	local b_local, b_remote = get_s2s_hosts(b);
	if (a_local or "") == (b_local or "") then return _sort_hosts(a_remote or "", b_remote or ""); end
	return _sort_hosts(a_local or "", b_local or "");
end

function def_env.s2s:show(match_jid, colspec)
	local print = self.session.print;
	local columns = get_colspec(colspec, { "id"; "host"; "dir"; "remote"; "ipv"; "secure"; "s2s_sasl"; "dialback" });
	local row = format_table(columns, 132);

	local function match(session)
		local host, remote = get_s2s_hosts(session);
		return not match_jid or host == match_jid or remote == match_jid;
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
		/function(session) return (session.to_host == domain or session.from_host == domain) and session or nil; end;
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
		local id = session.id or (session.type..tostring(session):match("[a-f0-9]+$"));
		if (match_id and match_id == id)
		or (session.from_host == from and session.to_host == to) then
			print(("Closing connection from %s to %s [%s]"):format(session.from_host, session.to_host, id));
			(session.close or s2smanager.destroy_session)(session, build_reason(text, condition));
			count = count + 1 ;
		end
	end
	return true, "Closed "..count.." s2s session"..((count == 1 and "") or "s");
end

function def_env.s2s:closeall(host, text, condition)
	local count = 0;
	local s2s_sessions = module:shared"/*/s2s/sessions";
	for _,session in pairs(s2s_sessions) do
		if not host or session.from_host == host or session.to_host == host then
			session:close(build_reason(text, condition));
			count = count + 1;
		end
	end
	if count == 0 then return false, "No sessions to close.";
	else return true, "Closed "..count.." s2s session"..((count == 1 and "") or "s"); end
end

def_env.host = {}; def_env.hosts = def_env.host;

function def_env.host:activate(hostname, config)
	return hostmanager.activate(hostname, config);
end
function def_env.host:deactivate(hostname, reason)
	return hostmanager.deactivate(hostname, reason);
end

function def_env.host:list()
	local print = self.session.print;
	local i = 0;
	local type;
	for host, host_session in iterators.sorted_pairs(prosody.hosts, _sort_hosts) do
		i = i + 1;
		type = host_session.type;
		if type == "local" then
			print(host);
		else
			type = module:context(host):get_option_string("component_module", type);
			if type ~= "component" then
				type = type .. " component";
			end
			print(("%s (%s)"):format(host, type));
		end
	end
	return true, i.." hosts";
end

def_env.port = {};

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

def_env.muc = {};

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

function def_env.muc:room(room_jid)
	local room_name, host = check_muc(room_jid);
	if not room_name then
		return room_name, host;
	end
	local room_obj = prosody.hosts[host].modules.muc.get_room_from_jid(room_jid);
	if not room_obj then
		return nil, "No such room: "..room_jid;
	end
	return setmetatable({ room = room_obj }, console_room_mt);
end

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

local um = require"core.usermanager";

local function coerce_roles(roles)
	if roles == "admin" then roles = "prosody:admin"; end
	if type(roles) == "string" then roles = { [roles] = true }; end
	if roles[1] then for i, role in ipairs(roles) do roles[role], roles[i] = true, nil; end end
	return roles;
end

def_env.user = {};
function def_env.user:create(jid, password, roles)
	local username, host = jid_split(jid);
	if not prosody.hosts[host] then
		return nil, "No such host: "..host;
	elseif um.user_exists(username, host) then
		return nil, "User exists";
	end
	local ok, err = um.create_user(username, password, host);
	if ok then
		if ok and roles then
			roles = coerce_roles(roles);
			local roles_ok, rerr = um.set_roles(jid, host, roles);
			if not roles_ok then return nil, "User created, but could not set roles: " .. tostring(rerr); end
		end
		return true, "User created";
	else
		return nil, "Could not create user: "..err;
	end
end

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

function def_env.user:password(jid, password)
	local username, host = jid_split(jid);
	if not prosody.hosts[host] then
		return nil, "No such host: "..host;
	elseif not um.user_exists(username, host) then
		return nil, "No such user";
	end
	local ok, err = um.set_password(username, password, host, nil);
	if ok then
		return true, "User password changed";
	else
		return nil, "Could not change password for user: "..err;
	end
end

function def_env.user:showroles(jid, host)
	local username, userhost = jid_split(jid);
	if host == nil then host = userhost; end
	if host ~= "*" and not prosody.hosts[host] then
		return nil, "No such host: "..host;
	elseif prosody.hosts[userhost] and not um.user_exists(username, userhost) then
		return nil, "No such user";
	end
	local roles = um.get_roles(jid, host);
	if not roles then return true, "No roles"; end
	local count = 0;
	local print = self.session.print;
	for role in pairs(roles) do
		count = count + 1;
		print(role);
	end
	return true, count == 1 and "1 role" or count.." roles";
end

-- user:roles("someone@example.com", "example.com", {"prosody:admin"})
-- user:roles("someone@example.com", {"prosody:admin"})
function def_env.user:roles(jid, host, new_roles)
	local username, userhost = jid_split(jid);
	if new_roles == nil then host, new_roles = userhost, host; end
	if host ~= "*" and not prosody.hosts[host] then
		return nil, "No such host: "..host;
	elseif prosody.hosts[userhost] and not um.user_exists(username, userhost) then
		return nil, "No such user";
	end
	if host == "*" then host = nil; end
	return um.set_roles(jid, host, coerce_roles(new_roles));
end

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

def_env.xmpp = {};

local new_id = require "util.id".medium;
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
		return ("pong from %s in %gs"):format(pong.stanza.attr.from, time.now() - time_start);
	end);
end

def_env.dns = {};
local adns = require"net.adns";

local function get_resolver(session)
	local resolver = session.dns_resolver;
	if not resolver then
		resolver = adns.resolver();
		session.dns_resolver = resolver;
	end
	return resolver;
end

function def_env.dns:lookup(name, typ, class)
	local resolver = get_resolver(self.session);
	return resolver:lookup_promise(name, typ, class)
end

function def_env.dns:addnameserver(...)
	local resolver = get_resolver(self.session);
	resolver._resolver:addnameserver(...)
	return true
end

function def_env.dns:setnameserver(...)
	local resolver = get_resolver(self.session);
	resolver._resolver:setnameserver(...)
	return true
end

function def_env.dns:purge()
	local resolver = get_resolver(self.session);
	resolver._resolver:purge()
	return true
end

function def_env.dns:cache()
	local resolver = get_resolver(self.session);
	return true, "Cache:\n"..tostring(resolver._resolver.cache)
end

def_env.http = {};

function def_env.http:list(hosts)
	local print = self.session.print;
	hosts = array.collect(set.new({ not hosts and "*" or nil }) + get_hosts_set(hosts)):sort(_sort_hosts);
	local output = format_table({
			{ title = "Module", width = "20%" },
			{ title = "URL", width = "80%" },
		}, 132);

	for _, host in ipairs(hosts) do
		local http_apps = modulemanager.get_items("http-provider", host);
		if #http_apps > 0 then
			local http_host = module:context(host):get_option_string("http_host");
			if host == "*" then
				print("Global HTTP endpoints available on all hosts:");
			else
				print("HTTP endpoints on "..host..(http_host and (" (using "..http_host.."):") or ":"));
			end
			print(output());
			for _, provider in ipairs(http_apps) do
				local mod = provider._provided_by;
				local url = module:context(host):http_url(provider.name, provider.default_path);
				mod = mod and "mod_"..mod or ""
				print(output{mod, url});
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

def_env.debug = {};

function def_env.debug:logevents(host)
	helpers.log_host_events(host);
	return true;
end

function def_env.debug:events(host, event)
	local events_obj;
	if host and host ~= "*" then
		if host == "http" then
			events_obj = require "net.http.server"._events;
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

function def_env.debug:timers()
	local print = self.session.print;
	local add_task = require"util.timer".add_task;
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

-- COMPAT: debug:timers() was timer:info() for some time in trunk
def_env.timer = { info = def_env.debug.timers };

def_env.stats = {};

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

function def_env.stats:show(name_filter)
	local statsman = require "core.statsmanager"
	local collect = statsman.collect
	if collect then
		-- force collection if in manual mode
		collect()
	end
	local metric_registry = statsman.get_metric_registry();
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
