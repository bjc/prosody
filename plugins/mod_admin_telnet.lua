-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:set_global();

local hostmanager = require "core.hostmanager";
local modulemanager = require "core.modulemanager";
local s2smanager = require "core.s2smanager";
local portmanager = require "core.portmanager";

local _G = _G;

local prosody = _G.prosody;
local hosts = prosody.hosts;
local incoming_s2s = prosody.incoming_s2s;

local console_listener = { default_port = 5582; default_mode = "*a"; interface = "127.0.0.1" };

local iterators = require "util.iterators";
local keys, values = iterators.keys, iterators.values;
local jid = require "util.jid";
local jid_bare, jid_split = jid.bare, jid.split;
local set, array = require "util.set", require "util.array";
local cert_verify_identity = require "util.x509".verify_identity;
local envload = require "util.envload".envload;
local envloadfile = require "util.envload".envloadfile;

local commands = module:shared("commands")
local def_env = module:shared("env");
local default_env_mt = { __index = def_env };
local core_post_stanza = prosody.core_post_stanza;

local function redirect_output(_G, session)
	local env = setmetatable({ print = session.print }, { __index = function (t, k) return rawget(_G, k); end });
	env.dofile = function(name)
		local f, err = envloadfile(name, env);
		if not f then return f, err; end
		return f();
	end;
	return env;
end

console = {};

function console:new_session(conn)
	local w = function(s) conn:write(s:gsub("\n", "\r\n")); end;
	local session = { conn = conn;
			send = function (t) w(tostring(t)); end;
			print = function (...)
				local t = {};
				for i=1,select("#", ...) do
					t[i] = tostring(select(i, ...));
				end
				w("| "..table.concat(t, "\t").."\n");
			end;
			disconnect = function () conn:close(); end;
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

function console:process_line(session, line)
	local useglobalenv;
	
	if line:match("^>") then
		line = line:gsub("^>", "");
		useglobalenv = true;
	elseif line == "\004" then
		commands["bye"](session, line);
		return;
	else
		local command = line:match("^%w+") or line:match("%p");
		if commands[command] then
			commands[command](session, line);
			return;
		end
	end
	
	session.env._ = line;
	
	local chunkname = "=console";
	local env = (useglobalenv and redirect_output(_G, session)) or session.env or nil
	local chunk, err = envload("return "..line, chunkname, env);
	if not chunk then
		chunk, err = envload(line, chunkname, env);
		if not chunk then
			err = err:gsub("^%[string .-%]:%d+: ", "");
			err = err:gsub("^:%d+: ", "");
			err = err:gsub("'<eof>'", "the end of the line");
			session.print("Sorry, I couldn't understand that... "..err);
			return;
		end
	end
	
	local ranok, taskok, message = pcall(chunk);
	
	if not (ranok or message or useglobalenv) and commands[line:lower()] then
		commands[line:lower()](session, line);
		return;
	end
	
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

local sessions = {};

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
		console:process_line(session, line);
		session.send(string.char(0));
	end
	session.partial_data = data:match("[^\n]+$");
end

function console_listener.ondisconnect(conn, err)
	local session = sessions[conn];
	if session then
		session.disconnect();
		sessions[conn] = nil;
	end
end

-- Console commands --
-- These are simple commands, not valid standalone in Lua

function commands.bye(session)
	session.print("See you! :)");
	session.closed = true;
	session.disconnect();
end
commands.quit, commands.exit = commands.bye, commands.bye;

commands["!"] = function (session, data)
	if data:match("^!!") and session.env._ then
		session.print("!> "..session.env._);
		return console_listener.onincoming(session.conn, session.env._);
	end
	local old, new = data:match("^!(.-[^\\])!(.-)!$");
	if old and new then
		local ok, res = pcall(string.gsub, session.env._, old, new);
		if not ok then
			session.print(res)
			return;
		end
		session.print("!> "..res);
		return console_listener.onincoming(session.conn, res);
	end
	session.print("Sorry, not sure what you want");
end


function commands.help(session, data)
	local print = session.print;
	local section = data:match("^help (%w+)");
	if not section then
		print [[Commands are divided into multiple sections. For help on a particular section, ]]
		print [[type: help SECTION (for example, 'help c2s'). Sections are: ]]
		print [[]]
		print [[c2s - Commands to manage local client-to-server sessions]]
		print [[s2s - Commands to manage sessions between this server and others]]
		print [[module - Commands to load/reload/unload modules/plugins]]
		print [[host - Commands to activate, deactivate and list virtual hosts]]
		print [[user - Commands to create and delete users, and change their passwords]]
		print [[server - Uptime, version, shutting down, etc.]]
		print [[port - Commands to manage ports the server is listening on]]
		print [[dns - Commands to manage and inspect the internal DNS resolver]]
		print [[config - Reloading the configuration, etc.]]
		print [[console - Help regarding the console itself]]
	elseif section == "c2s" then
		print [[c2s:show(jid) - Show all client sessions with the specified JID (or all if no JID given)]]
		print [[c2s:show_insecure() - Show all unencrypted client connections]]
		print [[c2s:show_secure() - Show all encrypted client connections]]
		print [[c2s:close(jid) - Close all sessions for the specified JID]]
	elseif section == "s2s" then
		print [[s2s:show(domain) - Show all s2s connections for the given domain (or all if no domain given)]]
		print [[s2s:close(from, to) - Close a connection from one domain to another]]
		print [[s2s:closeall(host) - Close all the incoming/outgoing s2s sessions to specified host]]
	elseif section == "module" then
		print [[module:load(module, host) - Load the specified module on the specified host (or all hosts if none given)]]
		print [[module:reload(module, host) - The same, but unloads and loads the module (saving state if the module supports it)]]
		print [[module:unload(module, host) - The same, but just unloads the module from memory]]
		print [[module:list(host) - List the modules loaded on the specified host]]
	elseif section == "host" then
		print [[host:activate(hostname) - Activates the specified host]]
		print [[host:deactivate(hostname) - Disconnects all clients on this host and deactivates]]
		print [[host:list() - List the currently-activated hosts]]
	elseif section == "user" then
		print [[user:create(jid, password) - Create the specified user account]]
		print [[user:password(jid, password) - Set the password for the specified user account]]
		print [[user:delete(jid) - Permanently remove the specified user account]]
		print [[user:list(hostname, pattern) - List users on the specified host, optionally filtering with a pattern]]
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
	elseif section == "config" then
		print [[config:reload() - Reload the server configuration. Modules may need to be reloaded for changes to take effect.]]
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
	end
	print [[]]
end

-- Session environment --
-- Anything in def_env will be accessible within the session as a global variable

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

function def_env.server:shutdown(reason)
	prosody.shutdown(reason);
	return true, "Shutdown initiated";
end

local function human(kb)
	local unit = "K";
	if kb > 1024 then
		kb, unit = kb/1024, "M";
	end
	return ("%0.2f%sB"):format(kb, unit);
end

function def_env.server:memory()
	if not pposix.meminfo then
		return true, "Lua is using "..collectgarbage("count");
	end
	local mem, lua_mem = pposix.meminfo(), collectgarbage("count");
	local print = self.session.print;
	print("Process: "..human((mem.allocated+mem.allocated_mmap)/1024));
	print("   Used: "..human(mem.used/1024).." ("..human(lua_mem).." by Lua)");
	print("   Free: "..human(mem.unused/1024).." ("..human(mem.returnable/1024).." returnable)");
	return true, "OK";
end

def_env.module = {};

local function get_hosts_set(hosts, module)
	if type(hosts) == "table" then
		if hosts[1] then
			return set.new(hosts);
		elseif hosts._items then
			return hosts;
		end
	elseif type(hosts) == "string" then
		return set.new { hosts };
	elseif hosts == nil then
		local mm = require "modulemanager";
		local hosts_set = set.new(array.collect(keys(prosody.hosts)))
			/ function (host) return (prosody.hosts[host].type == "local" or module and mm.is_loaded(host, module)) and host or nil; end;
		if module and mm.get_module("*", module) then
			hosts_set:add("*");
		end
		return hosts_set;
	end
end

function def_env.module:load(name, hosts, config)
	local mm = require "modulemanager";
	
	hosts = get_hosts_set(hosts);
	
	-- Load the module for each host
	local ok, err, count, mod = true, nil, 0, nil;
	for host in hosts do
		if (not mm.is_loaded(host, name)) then
			mod, err = mm.load(host, name, config);
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
	local mm = require "modulemanager";

	hosts = get_hosts_set(hosts, name);
	
	-- Unload the module for each host
	local ok, err, count = true, nil, 0;
	for host in hosts do
		if mm.is_loaded(host, name) then
			ok, err = mm.unload(host, name);
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

function def_env.module:reload(name, hosts)
	local mm = require "modulemanager";

	hosts = array.collect(get_hosts_set(hosts, name)):sort(function (a, b)
		if a == "*" then return true
		elseif b == "*" then return false
		else return a < b; end
	end);

	-- Reload the module for each host
	local ok, err, count = true, nil, 0;
	for _, host in ipairs(hosts) do
		if mm.is_loaded(host, name) then
			ok, err = mm.reload(host, name);
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
	if hosts == nil then
		hosts = array.collect(keys(prosody.hosts));
		table.insert(hosts, 1, "*");
	end
	if type(hosts) == "string" then
		hosts = { hosts };
	end
	if type(hosts) ~= "table" then
		return false, "Please supply a host or a list of hosts you would like to see";
	end
	
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
				print("    "..name);
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

function def_env.config:get(host, section, key)
	local config_get = require "core.configmanager".get
	return true, tostring(config_get(host, section, key));
end

function def_env.config:reload()
	local ok, err = prosody.reload_config();
	return ok, (ok and "Config reloaded (you may need to reload modules to take effect)") or tostring(err);
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

def_env.c2s = {};

local function show_c2s(callback)
	for hostname, host in pairs(hosts) do
		for username, user in pairs(host.sessions or {}) do
			for resource, session in pairs(user.sessions or {}) do
				local jid = username.."@"..hostname.."/"..resource;
				callback(jid, session);
			end
		end
	end
end

function def_env.c2s:count(match_jid)
	local count = 0;
	show_c2s(function (jid, session)
		if (not match_jid) or jid:match(match_jid) then
			count = count + 1;
		end		
	end);
	return true, "Total: "..count.." clients";
end

function def_env.c2s:show(match_jid)
	local print, count = self.session.print, 0;
	local curr_host;
	show_c2s(function (jid, session)
		if curr_host ~= session.host then
			curr_host = session.host;
			print(curr_host);
		end
		if (not match_jid) or jid:match(match_jid) then
			count = count + 1;
			local status, priority = "unavailable", tostring(session.priority or "-");
			if session.presence then
				status = session.presence:child_with_name("show");
				if status then
					status = status:get_text() or "[invalid!]";
				else
					status = "available";
				end
			end
			print("   "..jid.." - "..status.."("..priority..")");
		end		
	end);
	return true, "Total: "..count.." clients";
end

function def_env.c2s:show_insecure(match_jid)
	local print, count = self.session.print, 0;
	show_c2s(function (jid, session)
		if ((not match_jid) or jid:match(match_jid)) and not session.secure then
			count = count + 1;
			print(jid);
		end		
	end);
	return true, "Total: "..count.." insecure client connections";
end

function def_env.c2s:show_secure(match_jid)
	local print, count = self.session.print, 0;
	show_c2s(function (jid, session)
		if ((not match_jid) or jid:match(match_jid)) and session.secure then
			count = count + 1;
			print(jid);
		end		
	end);
	return true, "Total: "..count.." secure client connections";
end

function def_env.c2s:close(match_jid)
	local count = 0;
	show_c2s(function (jid, session)
		if jid == match_jid or jid_bare(jid) == match_jid then
			count = count + 1;
			session:close();
		end
	end);
	return true, "Total: "..count.." sessions closed";
end

local function session_flags(session, line)
	if session.cert_identity_status == "valid" then
		line[#line+1] = "(secure)";
	elseif session.secure then
		line[#line+1] = "(encrypted)";
	end
	if session.compressed then
		line[#line+1] = "(compressed)";
	end
	if session.smacks then
		line[#line+1] = "(sm)";
	end
	if session.conn and session.conn:ip():match(":") then
		line[#line+1] = "(IPv6)";
	end
	return table.concat(line, " ");
end

def_env.s2s = {};
function def_env.s2s:show(match_jid)
	local _print = self.session.print;
	local print = self.session.print;
	
	local count_in, count_out = 0,0;
	
	for host, host_session in pairs(hosts) do
		print = function (...) _print(host); _print(...); print = _print; end
		for remotehost, session in pairs(host_session.s2sout) do
			if (not match_jid) or remotehost:match(match_jid) or host:match(match_jid) then
				count_out = count_out + 1;
				print(session_flags(session, {"   ", host, "->", remotehost}));
				if session.sendq then
					print("        There are "..#session.sendq.." queued outgoing stanzas for this connection");
				end
				if session.type == "s2sout_unauthed" then
					if session.connecting then
						print("        Connection not yet established");
						if not session.srv_hosts then
							if not session.conn then
								print("        We do not yet have a DNS answer for this host's SRV records");
							else
								print("        This host has no SRV records, using A record instead");
							end
						elseif session.srv_choice then
							print("        We are on SRV record "..session.srv_choice.." of "..#session.srv_hosts);
							local srv_choice = session.srv_hosts[session.srv_choice];
							print("        Using "..(srv_choice.target or ".")..":"..(srv_choice.port or 5269));
						end
					elseif session.notopen then
						print("        The <stream> has not yet been opened");
					elseif not session.dialback_key then
						print("        Dialback has not been initiated yet");
					elseif session.dialback_key then
						print("        Dialback has been requested, but no result received");
					end
				end
			end
		end	
		local subhost_filter = function (h)
				return (match_jid and h:match(match_jid));
			end
		for session in pairs(incoming_s2s) do
			if session.to_host == host and ((not match_jid) or host:match(match_jid)
				or (session.from_host and session.from_host:match(match_jid))
				-- Pft! is what I say to list comprehensions
				or (session.hosts and #array.collect(keys(session.hosts)):filter(subhost_filter)>0)) then
				count_in = count_in + 1;
				print(session_flags(session, {"   ", host, "<-", session.from_host or "(unknown)"}));
				if session.type == "s2sin_unauthed" then
						print("        Connection not yet authenticated");
				end
				for name in pairs(session.hosts) do
					if name ~= session.from_host then
						print("        also hosts "..tostring(name));
					end
				end
			end
		end
		
		print = _print;
	end
	
	for session in pairs(incoming_s2s) do
		if not session.to_host and ((not match_jid) or session.from_host and session.from_host:match(match_jid)) then
			count_in = count_in + 1;
			print("Other incoming s2s connections");
			print("    (unknown) <- "..(session.from_host or "(unknown)"));			
		end
	end
	
	return true, "Total: "..count_out.." outgoing, "..count_in.." incoming connections";
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
	for depth, t in ipairs(errors) do
		print(
			("    %d: %s"):format(
				depth-1,
				table.concat(t, "\n|        ")
			)
		);
	end
end

function def_env.s2s:showcert(domain)
	local ser = require "util.serialization".serialize;
	local print = self.session.print;
	local domain_sessions = set.new(array.collect(keys(incoming_s2s)))
		/function(session) return session.from_host == domain and session or nil; end;
	for local_host in values(prosody.hosts) do
		local s2sout = local_host.s2sout;
		if s2sout and s2sout[domain] then
			domain_sessions:add(s2sout[domain]);
		end
	end
	local cert_set = {};
	for session in domain_sessions do
		local conn = session.conn;
		conn = conn and conn:socket();
		if not conn.getpeerchain then
			if conn.dohandshake then
				error("This version of LuaSec does not support certificate viewing");
			end
		else
			local certs = conn:getpeerchain();
			local cert = certs[1];
			if cert then
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

function def_env.s2s:close(from, to)
	local print, count = self.session.print, 0;
	
	if not (from and to) then
		return false, "Syntax: s2s:close('from', 'to') - Closes all s2s sessions from 'from' to 'to'";
	elseif from == to then
		return false, "Both from and to are the same... you can't do that :)";
	end
	
	if hosts[from] and not hosts[to] then
		-- Is an outgoing connection
		local session = hosts[from].s2sout[to];
		if not session then
			print("No outgoing connection from "..from.." to "..to)
		else
			(session.close or s2smanager.destroy_session)(session);
			count = count + 1;
			print("Closed outgoing session from "..from.." to "..to);
		end
	elseif hosts[to] and not hosts[from] then
		-- Is an incoming connection
		for session in pairs(incoming_s2s) do
			if session.to_host == to and session.from_host == from then
				(session.close or s2smanager.destroy_session)(session);
				count = count + 1;
			end
		end
		
		if count == 0 then
			print("No incoming connections from "..from.." to "..to);
		else
			print("Closed "..count.." incoming session"..((count == 1 and "") or "s").." from "..from.." to "..to);
		end
	elseif hosts[to] and hosts[from] then
		return false, "Both of the hostnames you specified are local, there are no s2s sessions to close";
	else
		return false, "Neither of the hostnames you specified are being used on this server";
	end
	
	return true, "Closed "..count.." s2s session"..((count == 1 and "") or "s");
end

function def_env.s2s:closeall(host)
        local count = 0;

        if not host or type(host) ~= "string" then return false, "wrong syntax: please use s2s:closeall('hostname.tld')"; end
        if hosts[host] then
                for session in pairs(incoming_s2s) do
                        if session.to_host == host then
                                (session.close or s2smanager.destroy_session)(session);
                                count = count + 1;
                        end
                end
                for _, session in pairs(hosts[host].s2sout) do
                        (session.close or s2smanager.destroy_session)(session);
                        count = count + 1;
                end
        else
                for session in pairs(incoming_s2s) do
			if session.from_host == host then
				(session.close or s2smanager.destroy_session)(session);
				count = count + 1;
			end
		end
		for _, h in pairs(hosts) do
			if h.s2sout[host] then
				(h.s2sout[host].close or s2smanager.destroy_session)(h.s2sout[host]);
				count = count + 1;
			end
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
	for host in values(array.collect(keys(prosody.hosts)):sort()) do
		i = i + 1;
		print(host);
	end
	return true, i.." hosts";
end

def_env.port = {};

function def_env.port:list()
	local print = self.session.print;
	local services = portmanager.get_active_services().data;
	local ordered_services, n_ports = {}, 0;
	for service, interfaces in pairs(services) do
		table.insert(ordered_services, service);
	end
	table.sort(ordered_services);
	for _, service in ipairs(ordered_services) do
		local ports_list = {};
		for interface, ports in pairs(services[service]) do
			for port in pairs(ports) do
				table.insert(ports_list, "["..interface.."]:"..port);
			end
		end
		n_ports = n_ports + #ports_list;
		print(service..": "..table.concat(ports_list, ", "));
	end
	return true, #ordered_services.." services listening on "..n_ports.." ports";
end

function def_env.port:close(close_port, close_interface)
	close_port = assert(tonumber(close_port), "Invalid port number");
	local n_closed = 0;
	local services = portmanager.get_active_services().data;
	for service, interfaces in pairs(services) do
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
	if not hosts[host] then
		return nil, "No such host: "..host;
	elseif not hosts[host].modules.muc then
		return nil, "Host '"..host.."' is not a MUC service";
	end
	return room_name, host;
end

function def_env.muc:create(room_jid)
	local room, host = check_muc(room_jid);
	return hosts[host].modules.muc.create_room(room_jid);
end

function def_env.muc:room(room_jid)
	local room_name, host = check_muc(room_jid);
	local room_obj = hosts[host].modules.muc.rooms[room_jid];
	if not room_obj then
		return nil, "No such room: "..room_jid;
	end
	return setmetatable({ room = room_obj }, console_room_mt);
end

local um = require"core.usermanager";

def_env.user = {};
function def_env.user:create(jid, password)
	local username, host = jid_split(jid);
	if um.user_exists(username, host) then
		return nil, "User exists";
	end
	local ok, err = um.create_user(username, password, host);
	if ok then
		return true, "User created";
	else
		return nil, "Could not create user: "..err;
	end
end

function def_env.user:delete(jid)
	local username, host = jid_split(jid);
	if not um.user_exists(username, host) then
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
	if not um.user_exists(username, host) then
		return nil, "No such user";
	end
	local ok, err = um.set_password(username, password, host);
	if ok then
		return true, "User password changed";
	else
		return nil, "Could not change password for user: "..err;
	end
end

function def_env.user:list(host, pat)
	if not host then
		return nil, "No host given";
	elseif not hosts[host] then
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

local st = require "util.stanza";
function def_env.xmpp:ping(localhost, remotehost)
	if hosts[localhost] then
		core_post_stanza(hosts[localhost],
			st.iq{ from=localhost, to=remotehost, type="get", id="ping" }
				:tag("ping", {xmlns="urn:xmpp:ping"}));
		return true, "Sent ping";
	else
		return nil, "No such host";
	end
end

def_env.dns = {};
local adns = require"net.adns";
local dns = require"net.dns";

function def_env.dns:lookup(name, typ, class)
	local ret = "Query sent";
	local print = self.session.print;
	local function handler(...)
		ret = "Got response";
		print(...);
	end
	adns.lookup(handler, name, typ, class);
	return true, ret;
end

function def_env.dns:addnameserver(...)
	dns.addnameserver(...)
	return true
end

function def_env.dns:setnameserver(...)
	dns.setnameserver(...)
	return true
end

function def_env.dns:purge()
	dns.purge()
	return true
end

function def_env.dns:cache()
	return true, "Cache:\n"..tostring(dns.cache())
end

-------------

function printbanner(session)
	local option = module:get_option("console_banner");
	if option == nil or option == "full" or option == "graphic" then
		session.print [[
                   ____                \   /     _       
                    |  _ \ _ __ ___  ___  _-_   __| |_   _ 
                    | |_) | '__/ _ \/ __|/ _ \ / _` | | | |
                    |  __/| | | (_) \__ \ |_| | (_| | |_| |
                    |_|   |_|  \___/|___/\___/ \__,_|\__, |
                    A study in simplicity            |___/ 

]]
	end
	if option == nil or option == "short" or option == "full" then
	session.print("Welcome to the Prosody administration console. For a list of commands, type: help");
	session.print("You may find more help on using this console in our online documentation at ");
	session.print("http://prosody.im/doc/console\n");
	end
	if option and option ~= "short" and option ~= "full" and option ~= "graphic" then
		if type(option) == "string" then
			session.print(option)
		elseif type(option) == "function" then
			module:log("warn", "Using functions as value for the console_banner option is no longer supported");
		end
	end
end

module:provides("net", {
	name = "console";
	listener = console_listener;
	default_port = 5582;
	private = true;
});
