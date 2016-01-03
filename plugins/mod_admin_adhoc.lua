-- Copyright (C) 2009-2011 Florian Zeitz
--
-- This file is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local _G = _G;

local prosody = _G.prosody;
local hosts = prosody.hosts;
local t_concat = table.concat;
local t_sort = table.sort;

local module_host = module:get_host();

local keys = require "util.iterators".keys;
local usermanager_user_exists = require "core.usermanager".user_exists;
local usermanager_create_user = require "core.usermanager".create_user;
local usermanager_delete_user = require "core.usermanager".delete_user;
local usermanager_get_password = require "core.usermanager".get_password;
local usermanager_set_password = require "core.usermanager".set_password;
local hostmanager_activate = require "core.hostmanager".activate;
local hostmanager_deactivate = require "core.hostmanager".deactivate;
local rm_load_roster = require "core.rostermanager".load_roster;
local st, jid = require "util.stanza", require "util.jid";
local timer_add_task = require "util.timer".add_task;
local dataforms_new = require "util.dataforms".new;
local array = require "util.array";
local modulemanager = require "core.modulemanager";
local core_post_stanza = prosody.core_post_stanza;
local adhoc_simple = require "util.adhoc".new_simple_form;
local adhoc_initial = require "util.adhoc".new_initial_data_form;
local set = require"util.set";

module:depends("adhoc");
local adhoc_new = module:require "adhoc".new;

local function generate_error_message(errors)
	local errmsg = {};
	for name, err in pairs(errors) do
		errmsg[#errmsg + 1] = name .. ": " .. err;
	end
	return { status = "completed", error = { message = t_concat(errmsg, "\n") } };
end

-- Adding a new user
local add_user_layout = dataforms_new{
	title = "Adding a User";
	instructions = "Fill out this form to add a user.";

	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "accountjid", type = "jid-single", required = true, label = "The Jabber ID for the account to be added" };
	{ name = "password", type = "text-private", label = "The password for this account" };
	{ name = "password-verify", type = "text-private", label = "Retype password" };
};

local add_user_command_handler = adhoc_simple(add_user_layout, function(fields, err)
	if err then
		return generate_error_message(err);
	end
	local username, host, resource = jid.split(fields.accountjid);
	if module_host ~= host then
		return { status = "completed", error = { message = "Trying to add a user on " .. host .. " but command was sent to " .. module_host}};
	end
	if (fields["password"] == fields["password-verify"]) and username and host then
		if usermanager_user_exists(username, host) then
			return { status = "completed", error = { message = "Account already exists" } };
		else
			if usermanager_create_user(username, fields.password, host) then
				module:log("info", "Created new account %s@%s", username, host);
				return { status = "completed", info = "Account successfully created" };
			else
				return { status = "completed", error = { message = "Failed to write data to disk" } };
			end
		end
	else
		module:log("debug", "Invalid data, password mismatch or empty username while creating account for %s", fields.accountjid or "<nil>");
		return { status = "completed", error = { message = "Invalid data.\nPassword mismatch, or empty username" } };
	end
end);

-- Changing a user's password
local change_user_password_layout = dataforms_new{
	title = "Changing a User Password";
	instructions = "Fill out this form to change a user's password.";

	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "accountjid", type = "jid-single", required = true, label = "The Jabber ID for this account" };
	{ name = "password", type = "text-private", required = true, label = "The password for this account" };
};

local change_user_password_command_handler = adhoc_simple(change_user_password_layout, function(fields, err)
	if err then
		return generate_error_message(err);
	end
	local username, host, resource = jid.split(fields.accountjid);
	if module_host ~= host then
		return { status = "completed", error = { message = "Trying to change the password of a user on " .. host .. " but command was sent to " .. module_host}};
	end
	if usermanager_user_exists(username, host) and usermanager_set_password(username, fields.password, host) then
		return { status = "completed", info = "Password successfully changed" };
	else
		return { status = "completed", error = { message = "User does not exist" } };
	end
end);

-- Reloading the config
local function config_reload_handler(self, data, state)
	local ok, err = prosody.reload_config();
	if ok then
		return { status = "completed", info = "Configuration reloaded (modules may need to be reloaded for this to have an effect)" };
	else
		return { status = "completed", error = { message = "Failed to reload config: " .. tostring(err) } };
	end
end

-- Deleting a user's account
local delete_user_layout = dataforms_new{
	title = "Deleting a User";
	instructions = "Fill out this form to delete a user.";

	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "accountjids", type = "jid-multi", required = true, label = "The Jabber ID(s) to delete" };
};

local delete_user_command_handler = adhoc_simple(delete_user_layout, function(fields, err)
	if err then
		return generate_error_message(err);
	end
	local failed = {};
	local succeeded = {};
	for _, aJID in ipairs(fields.accountjids) do
		local username, host, resource = jid.split(aJID);
		if (host == module_host) and  usermanager_user_exists(username, host) and usermanager_delete_user(username, host) then
			module:log("debug", "User %s has been deleted", aJID);
			succeeded[#succeeded+1] = aJID;
		else
			module:log("debug", "Tried to delete non-existant user %s", aJID);
			failed[#failed+1] = aJID;
		end
	end
	return {status = "completed", info = (#succeeded ~= 0 and
			"The following accounts were successfully deleted:\n"..t_concat(succeeded, "\n").."\n" or "")..
			(#failed ~= 0 and
			"The following accounts could not be deleted:\n"..t_concat(failed, "\n") or "") };
end);

-- Ending a user's session
local function disconnect_user(match_jid)
	local node, hostname, givenResource = jid.split(match_jid);
	local host = hosts[hostname];
	local sessions = host.sessions[node] and host.sessions[node].sessions;
	for resource, session in pairs(sessions or {}) do
		if not givenResource or (resource == givenResource) then
			module:log("debug", "Disconnecting %s@%s/%s", node, hostname, resource);
			session:close();
		end
	end
	return true;
end

local end_user_session_layout = dataforms_new{
	title = "Ending a User Session";
	instructions = "Fill out this form to end a user's session.";

	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "accountjids", type = "jid-multi", label = "The Jabber ID(s) for which to end sessions", required = true };
};

local end_user_session_handler = adhoc_simple(end_user_session_layout, function(fields, err)
	if err then
		return generate_error_message(err);
	end
	local failed = {};
	local succeeded = {};
	for _, aJID in ipairs(fields.accountjids) do
		local username, host, resource = jid.split(aJID);
		if (host == module_host) and  usermanager_user_exists(username, host) and disconnect_user(aJID) then
			succeeded[#succeeded+1] = aJID;
		else
			failed[#failed+1] = aJID;
		end
	end
	return {status = "completed", info = (#succeeded ~= 0 and
		"The following accounts were successfully disconnected:\n"..t_concat(succeeded, "\n").."\n" or "")..
		(#failed ~= 0 and
		"The following accounts could not be disconnected:\n"..t_concat(failed, "\n") or "") };
end);

-- Getting a user's password
local get_user_password_layout = dataforms_new{
	title = "Getting User's Password";
	instructions = "Fill out this form to get a user's password.";

	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "accountjid", type = "jid-single", required = true, label = "The Jabber ID for which to retrieve the password" };
};

local get_user_password_result_layout = dataforms_new{
	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "accountjid", type = "jid-single", label = "JID" };
	{ name = "password", type = "text-single", label = "Password" };
};

local get_user_password_handler = adhoc_simple(get_user_password_layout, function(fields, err)
	if err then
		return generate_error_message(err);
	end
	local user, host, resource = jid.split(fields.accountjid);
	local accountjid = "";
	local password = "";
	if host ~= module_host then
		return { status = "completed", error = { message = "Tried to get password for a user on " .. host .. " but command was sent to " .. module_host } };
	elseif usermanager_user_exists(user, host) then
		accountjid = fields.accountjid;
		password = usermanager_get_password(user, host);
	else
		return { status = "completed", error = { message = "User does not exist" } };
	end
	return { status = "completed", result = { layout = get_user_password_result_layout, values = {accountjid = accountjid, password = password} } };
end);

-- Getting a user's roster
local get_user_roster_layout = dataforms_new{
	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "accountjid", type = "jid-single", required = true, label = "The Jabber ID for which to retrieve the roster" };
};

local get_user_roster_result_layout = dataforms_new{
	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "accountjid", type = "jid-single", label = "This is the roster for" };
	{ name = "roster", type = "text-multi", label = "Roster XML" };
};

local get_user_roster_handler = adhoc_simple(get_user_roster_layout, function(fields, err)
	if err then
		return generate_error_message(err);
	end

	local user, host, resource = jid.split(fields.accountjid);
	if host ~= module_host then
		return { status = "completed", error = { message = "Tried to get roster for a user on " .. host .. " but command was sent to " .. module_host } };
	elseif not usermanager_user_exists(user, host) then
		return { status = "completed", error = { message = "User does not exist" } };
	end
	local roster = rm_load_roster(user, host);

	local query = st.stanza("query", { xmlns = "jabber:iq:roster" });
	for jid in pairs(roster) do
		if jid then
			query:tag("item", {
				jid = jid,
				subscription = roster[jid].subscription,
				ask = roster[jid].ask,
				name = roster[jid].name,
			});
			for group in pairs(roster[jid].groups) do
				query:tag("group"):text(group):up();
			end
			query:up();
		end
	end

	local query_text = tostring(query):gsub("><", ">\n<");

	local result = get_user_roster_result_layout:form({ accountjid = user.."@"..host, roster = query_text }, "result");
	result:add_child(query);
	return { status = "completed", other = result };
end);

-- Getting user statistics
local get_user_stats_layout = dataforms_new{
	title = "Get User Statistics";
	instructions = "Fill out this form to gather user statistics.";

	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "accountjid", type = "jid-single", required = true, label = "The Jabber ID for statistics" };
};

local get_user_stats_result_layout = dataforms_new{
	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "ipaddresses", type = "text-multi", label = "IP Addresses" };
	{ name = "rostersize", type = "text-single", label = "Roster size" };
	{ name = "onlineresources", type = "text-multi", label = "Online Resources" };
};

local get_user_stats_handler = adhoc_simple(get_user_stats_layout, function(fields, err)
	if err then
		return generate_error_message(err);
	end

	local user, host, resource = jid.split(fields.accountjid);
	if host ~= module_host then
		return { status = "completed", error = { message = "Tried to get stats for a user on " .. host .. " but command was sent to " .. module_host } };
	elseif not usermanager_user_exists(user, host) then
		return { status = "completed", error = { message = "User does not exist" } };
	end
	local roster = rm_load_roster(user, host);
	local rostersize = 0;
	local IPs = "";
	local resources = "";
	for jid in pairs(roster) do
		if jid then
			rostersize = rostersize + 1;
		end
	end
	for resource, session in pairs((hosts[host].sessions[user] and hosts[host].sessions[user].sessions) or {}) do
		resources = resources .. "\n" .. resource;
		IPs = IPs .. "\n" .. session.ip;
	end
	return { status = "completed", result = {layout = get_user_stats_result_layout, values = {ipaddresses = IPs, rostersize = tostring(rostersize),
		onlineresources = resources}} };
end);

-- Getting a list of online users
local get_online_users_layout = dataforms_new{
	title = "Getting List of Online Users";
	instructions = "How many users should be returned at most?";

	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "max_items", type = "list-single", label = "Maximum number of users",
		value = { "25", "50", "75", "100", "150", "200", "all" } };
	{ name = "details", type = "boolean", label = "Show details" };
};

local get_online_users_result_layout = dataforms_new{
	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "onlineuserjids", type = "text-multi", label = "The list of all online users" };
};

local get_online_users_command_handler = adhoc_simple(get_online_users_layout, function(fields, err)
	if err then
		return generate_error_message(err);
	end

	local max_items = nil
	if fields.max_items ~= "all" then
		max_items = tonumber(fields.max_items);
	end
	local count = 0;
	local users = {};
	for username, user in pairs(hosts[module_host].sessions or {}) do
		if (max_items ~= nil) and (count >= max_items) then
			break;
		end
		users[#users+1] = username.."@"..module_host;
		count = count + 1;
		if fields.details then
			for resource, session in pairs(user.sessions or {}) do
				local status, priority, ip = "unavailable", tostring(session.priority or "-"), session.ip or "<unknown>";
				if session.presence then
					status = session.presence:child_with_name("show");
					if status then
						status = status:get_text() or "[invalid!]";
					else
						status = "available";
					end
				end
				users[#users+1] = " - "..resource..": "..status.."("..priority.."), IP: ["..ip.."]";
			end
		end
	end
	return { status = "completed", result = {layout = get_online_users_result_layout, values = {onlineuserjids=t_concat(users, "\n")}} };
end);

-- Getting a list of S2S connections (this host)
local list_s2s_this_result = dataforms_new {
	title = "List of S2S connections on this host";

	{ name = "FORM_TYPE", type = "hidden", value = "http://prosody.im/protocol/s2s#list" };
	{ name = "sessions", type = "text-multi", label = "Connections:" };
	{ name = "num_in", type = "text-single", label = "#incomming connections:" };
	{ name = "num_out", type = "text-single", label = "#outgoing connections:" };
};

local function session_flags(session, line)
	line = line or {};

	if session.id then
		line[#line+1] = "["..session.id.."]"
	else
		line[#line+1] = "["..session.type..(tostring(session):match("%x*$")).."]"
	end

	local flags = {};
	if session.cert_identity_status == "valid" then
		flags[#flags+1] = "authenticated";
	end
	if session.secure then
		flags[#flags+1] = "encrypted";
	end
	if session.compressed then
		flags[#flags+1] = "compressed";
	end
	if session.smacks then
		flags[#flags+1] = "sm";
	end
	if session.ip and session.ip:match(":") then
		flags[#flags+1] = "IPv6";
	end
	line[#line+1] = "("..t_concat(flags, ", ")..")";

	return t_concat(line, " ");
end

local function list_s2s_this_handler(self, data, state)
	local count_in, count_out = 0, 0;
	local s2s_list = {};

	local s2s_sessions = module:shared"/*/s2s/sessions";
	for _, session in pairs(s2s_sessions) do
		local remotehost, localhost, direction;
		if session.direction == "outgoing" then
			direction = "->";
			count_out = count_out + 1;
			remotehost, localhost = session.to_host or "?", session.from_host or "?";
		else
			direction = "<-";
			count_in = count_in + 1;
			remotehost, localhost = session.from_host or "?", session.to_host or "?";
		end
		local sess_lines = { r = remotehost,
			session_flags(session, { "", direction, remotehost or "?" })};

		if remotehost:match(module_host) or localhost:match(module_host) then
			s2s_list[#s2s_list+1] = sess_lines;
		end
	end

	t_sort(s2s_list, function(a, b)
		return a.r < b.r;
	end);

	for i, sess_lines in ipairs(s2s_list) do
		s2s_list[i] = sess_lines[1];
	end

	return { status = "completed", result = { layout = list_s2s_this_result; values = {
		sessions = t_concat(s2s_list, "\n"),
		num_in = tostring(count_in),
		num_out = tostring(count_out)
	} } };
end

-- Getting a list of loaded modules
local list_modules_result = dataforms_new {
	title = "List of loaded modules";

	{ name = "FORM_TYPE", type = "hidden", value = "http://prosody.im/protocol/modules#list" };
	{ name = "modules", type = "text-multi", label = "The following modules are loaded:" };
};

local function list_modules_handler(self, data, state)
	local modules = array.collect(keys(hosts[module_host].modules)):sort():concat("\n");
	return { status = "completed", result = { layout = list_modules_result; values = { modules = modules } } };
end

-- Loading a module
local load_module_layout = dataforms_new {
	title = "Load module";
	instructions = "Specify the module to be loaded";

	{ name = "FORM_TYPE", type = "hidden", value = "http://prosody.im/protocol/modules#load" };
	{ name = "module", type = "text-single", required = true, label = "Module to be loaded:"};
};

local load_module_handler = adhoc_simple(load_module_layout, function(fields, err)
	if err then
		return generate_error_message(err);
	end
	if modulemanager.is_loaded(module_host, fields.module) then
		return { status = "completed", info = "Module already loaded" };
	end
	local ok, err = modulemanager.load(module_host, fields.module);
	if ok then
		return { status = "completed", info = 'Module "'..fields.module..'" successfully loaded on host "'..module_host..'".' };
	else
		return { status = "completed", error = { message = 'Failed to load module "'..fields.module..'" on host "'..module_host..
		'". Error was: "'..tostring(err or "<unspecified>")..'"' } };
	end
end);

-- Globally loading a module
local globally_load_module_layout = dataforms_new {
	title = "Globally load module";
	instructions = "Specify the module to be loaded on all hosts";

	{ name = "FORM_TYPE", type = "hidden", value = "http://prosody.im/protocol/modules#global-load" };
	{ name = "module", type = "text-single", required = true, label = "Module to globally load:"};
};

local globally_load_module_handler = adhoc_simple(globally_load_module_layout, function(fields, err)
	local ok_list, err_list = {}, {};

	if err then
		return generate_error_message(err);
	end

	local ok, err = modulemanager.load(module_host, fields.module);
	if ok then
		ok_list[#ok_list + 1] = module_host;
	else
		err_list[#err_list + 1] = module_host .. " (Error: " .. tostring(err) .. ")";
	end

	-- Is this a global module?
	if modulemanager.is_loaded("*", fields.module) and not modulemanager.is_loaded(module_host, fields.module) then
		return { status = "completed", info = 'Global module '..fields.module..' loaded.' };
	end

	-- This is either a shared or "normal" module, load it on all other hosts
	for host_name, host in pairs(hosts) do
		if host_name ~= module_host and host.type == "local" then
			local ok, err = modulemanager.load(host_name, fields.module);
			if ok then
				ok_list[#ok_list + 1] = host_name;
			else
				err_list[#err_list + 1] = host_name .. " (Error: " .. tostring(err) .. ")";
			end
		end
	end

	local info = (#ok_list > 0 and ("The module "..fields.module.." was successfully loaded onto the hosts:\n"..t_concat(ok_list, "\n")) or "")
		.. ((#ok_list > 0 and #err_list > 0) and "\n" or "") ..
		(#err_list > 0 and ("Failed to load the module "..fields.module.." onto the hosts:\n"..t_concat(err_list, "\n")) or "");
	return { status = "completed", info = info };
end);

-- Reloading modules
local reload_modules_layout = dataforms_new {
	title = "Reload modules";
	instructions = "Select the modules to be reloaded";

	{ name = "FORM_TYPE", type = "hidden", value = "http://prosody.im/protocol/modules#reload" };
	{ name = "modules", type = "list-multi", required = true, label = "Modules to be reloaded:"};
};

local reload_modules_handler = adhoc_initial(reload_modules_layout, function()
	return { modules = array.collect(keys(hosts[module_host].modules)):sort() };
end, function(fields, err)
	if err then
		return generate_error_message(err);
	end
	local ok_list, err_list = {}, {};
	for _, module in ipairs(fields.modules) do
		local ok, err = modulemanager.reload(module_host, module);
		if ok then
			ok_list[#ok_list + 1] = module;
		else
			err_list[#err_list + 1] = module .. "(Error: " .. tostring(err) .. ")";
		end
	end
	local info = (#ok_list > 0 and ("The following modules were successfully reloaded on host "..module_host..":\n"..t_concat(ok_list, "\n")) or "")
		.. ((#ok_list > 0 and #err_list > 0) and "\n" or "") ..
		(#err_list > 0 and ("Failed to reload the following modules on host "..module_host..":\n"..t_concat(err_list, "\n")) or "");
	return { status = "completed", info = info };
end);

-- Globally reloading a module
local globally_reload_module_layout = dataforms_new {
	title = "Globally reload module";
	instructions = "Specify the module to reload on all hosts";

	{ name = "FORM_TYPE", type = "hidden", value = "http://prosody.im/protocol/modules#global-reload" };
	{ name = "module", type = "list-single", required = true, label = "Module to globally reload:"};
};

local globally_reload_module_handler = adhoc_initial(globally_reload_module_layout, function()
	local loaded_modules = array(keys(modulemanager.get_modules("*")));
	for _, host in pairs(hosts) do
		loaded_modules:append(array(keys(host.modules)));
	end
	loaded_modules = array(set.new(loaded_modules):items()):sort();
	return { module = loaded_modules };
end, function(fields, err)
	local is_global = false;

	if err then
		return generate_error_message(err);
	end

	if modulemanager.is_loaded("*", fields.module) then
		local ok, err = modulemanager.reload("*", fields.module);
		if not ok then
			return { status = "completed", info = 'Global module '..fields.module..' failed to reload: '..err };
		end
		is_global = true;
	end

	local ok_list, err_list = {}, {};
	for host_name, host in pairs(hosts) do
		if modulemanager.is_loaded(host_name, fields.module)  then
			local ok, err = modulemanager.reload(host_name, fields.module);
			if ok then
				ok_list[#ok_list + 1] = host_name;
			else
				err_list[#err_list + 1] = host_name .. " (Error: " .. tostring(err) .. ")";
			end
		end
	end

	if #ok_list == 0 and #err_list == 0 then
		if is_global then
			return { status = "completed", info = 'Successfully reloaded global module '..fields.module };
		else
			return { status = "completed", info = 'Module '..fields.module..' not loaded on any host.' };
		end
	end

	local info = (#ok_list > 0 and ("The module "..fields.module.." was successfully reloaded on the hosts:\n"..t_concat(ok_list, "\n")) or "")
		.. ((#ok_list > 0 and #err_list > 0) and "\n" or "") ..
		(#err_list > 0 and ("Failed to reload the module "..fields.module.." on the hosts:\n"..t_concat(err_list, "\n")) or "");
	return { status = "completed", info = info };
end);

local function send_to_online(message, server)
	local sessions;
	if server then
		sessions = { [server] = hosts[server] };
	else
		sessions = hosts;
	end

	local c = 0;
	for domain, session in pairs(sessions) do
		for user in pairs(session.sessions or {}) do
			c = c + 1;
			message.attr.from = domain;
			message.attr.to = user.."@"..domain;
			core_post_stanza(session, message);
		end
	end

	return c;
end

-- Shutting down the service
local shut_down_service_layout = dataforms_new{
	title = "Shutting Down the Service";
	instructions = "Fill out this form to shut down the service.";

	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "delay", type = "list-single", label = "Time delay before shutting down",
		value = { {label = "30 seconds", value = "30"},
			  {label = "60 seconds", value = "60"},
			  {label = "90 seconds", value = "90"},
			  {label = "2 minutes", value = "120"},
			  {label = "3 minutes", value = "180"},
			  {label = "4 minutes", value = "240"},
			  {label = "5 minutes", value = "300"},
		};
	};
	{ name = "announcement", type = "text-multi", label = "Announcement" };
};

local shut_down_service_handler = adhoc_simple(shut_down_service_layout, function(fields, err)
	if err then
		return generate_error_message(err);
	end

	if fields.announcement and #fields.announcement > 0 then
		local message = st.message({type = "headline"}, fields.announcement):up()
			:tag("subject"):text("Server is shutting down");
		send_to_online(message);
	end

	timer_add_task(tonumber(fields.delay or "5"), function(time) prosody.shutdown("Shutdown by adhoc command") end);

	return { status = "completed", info = "Server is about to shut down" };
end);

-- Unloading modules
local unload_modules_layout = dataforms_new {
	title = "Unload modules";
	instructions = "Select the modules to be unloaded";

	{ name = "FORM_TYPE", type = "hidden", value = "http://prosody.im/protocol/modules#unload" };
	{ name = "modules", type = "list-multi", required = true, label = "Modules to be unloaded:"};
};

local unload_modules_handler = adhoc_initial(unload_modules_layout, function()
	return { modules = array.collect(keys(hosts[module_host].modules)):sort() };
end, function(fields, err)
	if err then
		return generate_error_message(err);
	end
	local ok_list, err_list = {}, {};
	for _, module in ipairs(fields.modules) do
		local ok, err = modulemanager.unload(module_host, module);
		if ok then
			ok_list[#ok_list + 1] = module;
		else
			err_list[#err_list + 1] = module .. "(Error: " .. tostring(err) .. ")";
		end
	end
	local info = (#ok_list > 0 and ("The following modules were successfully unloaded on host "..module_host..":\n"..t_concat(ok_list, "\n")) or "")
		.. ((#ok_list > 0 and #err_list > 0) and "\n" or "") ..
		(#err_list > 0 and ("Failed to unload the following modules on host "..module_host..":\n"..t_concat(err_list, "\n")) or "");
	return { status = "completed", info = info };
end);

-- Globally unloading a module
local globally_unload_module_layout = dataforms_new {
	title = "Globally unload module";
	instructions = "Specify a module to unload on all hosts";

	{ name = "FORM_TYPE", type = "hidden", value = "http://prosody.im/protocol/modules#global-unload" };
	{ name = "module", type = "list-single", required = true, label = "Module to globally unload:"};
};

local globally_unload_module_handler = adhoc_initial(globally_unload_module_layout, function()
	local loaded_modules = array(keys(modulemanager.get_modules("*")));
	for _, host in pairs(hosts) do
		loaded_modules:append(array(keys(host.modules)));
	end
	loaded_modules = array(set.new(loaded_modules):items()):sort();
	return { module = loaded_modules };
end, function(fields, err)
	local is_global = false;
	if err then
		return generate_error_message(err);
	end

	if modulemanager.is_loaded("*", fields.module) then
		local ok, err = modulemanager.unload("*", fields.module);
		if not ok then
			return { status = "completed", info = 'Global module '..fields.module..' failed to unload: '..err };
		end
		is_global = true;
	end

	local ok_list, err_list = {}, {};
	for host_name, host in pairs(hosts) do
		if modulemanager.is_loaded(host_name, fields.module)  then
			local ok, err = modulemanager.unload(host_name, fields.module);
			if ok then
				ok_list[#ok_list + 1] = host_name;
			else
				err_list[#err_list + 1] = host_name .. " (Error: " .. tostring(err) .. ")";
			end
		end
	end

	if #ok_list == 0 and #err_list == 0 then
		if is_global then
			return { status = "completed", info = 'Successfully unloaded global module '..fields.module };
		else
			return { status = "completed", info = 'Module '..fields.module..' not loaded on any host.' };
		end
	end

	local info = (#ok_list > 0 and ("The module "..fields.module.." was successfully unloaded on the hosts:\n"..t_concat(ok_list, "\n")) or "")
		.. ((#ok_list > 0 and #err_list > 0) and "\n" or "") ..
		(#err_list > 0 and ("Failed to unload the module "..fields.module.." on the hosts:\n"..t_concat(err_list, "\n")) or "");
	return { status = "completed", info = info };
end);

-- Activating a host
local activate_host_layout = dataforms_new {
	title = "Activate host";
	instructions = "";

	{ name = "FORM_TYPE", type = "hidden", value = "http://prosody.im/protocol/hosts#activate" };
	{ name = "host", type = "text-single", required = true, label = "Host:"};
};

local activate_host_handler = adhoc_simple(activate_host_layout, function(fields, err)
	if err then
		return generate_error_message(err);
	end
	local ok, err = hostmanager_activate(fields.host);

	if ok then
		return { status = "completed", info = fields.host .. " activated" };
	else
		return { status = "canceled", error = err }
	end
end);

-- Deactivating a host
local deactivate_host_layout = dataforms_new {
	title = "Deactivate host";
	instructions = "";

	{ name = "FORM_TYPE", type = "hidden", value = "http://prosody.im/protocol/hosts#activate" };
	{ name = "host", type = "text-single", required = true, label = "Host:"};
};

local deactivate_host_handler = adhoc_simple(deactivate_host_layout, function(fields, err)
	if err then
		return generate_error_message(err);
	end
	local ok, err = hostmanager_deactivate(fields.host);

	if ok then
		return { status = "completed", info = fields.host .. " deactivated" };
	else
		return { status = "canceled", error = err }
	end
end);


local add_user_desc = adhoc_new("Add User", "http://jabber.org/protocol/admin#add-user", add_user_command_handler, "admin");
local change_user_password_desc = adhoc_new("Change User Password", "http://jabber.org/protocol/admin#change-user-password", change_user_password_command_handler, "admin");
local config_reload_desc = adhoc_new("Reload configuration", "http://prosody.im/protocol/config#reload", config_reload_handler, "global_admin");
local delete_user_desc = adhoc_new("Delete User", "http://jabber.org/protocol/admin#delete-user", delete_user_command_handler, "admin");
local end_user_session_desc = adhoc_new("End User Session", "http://jabber.org/protocol/admin#end-user-session", end_user_session_handler, "admin");
local get_user_password_desc = adhoc_new("Get User Password", "http://jabber.org/protocol/admin#get-user-password", get_user_password_handler, "admin");
local get_user_roster_desc = adhoc_new("Get User Roster","http://jabber.org/protocol/admin#get-user-roster", get_user_roster_handler, "admin");
local get_user_stats_desc = adhoc_new("Get User Statistics","http://jabber.org/protocol/admin#user-stats", get_user_stats_handler, "admin");
local get_online_users_desc = adhoc_new("Get List of Online Users", "http://jabber.org/protocol/admin#get-online-users-list", get_online_users_command_handler, "admin");
local list_s2s_this_desc = adhoc_new("List S2S connections", "http://prosody.im/protocol/s2s#list", list_s2s_this_handler, "admin");
local list_modules_desc = adhoc_new("List loaded modules", "http://prosody.im/protocol/modules#list", list_modules_handler, "admin");
local load_module_desc = adhoc_new("Load module", "http://prosody.im/protocol/modules#load", load_module_handler, "admin");
local globally_load_module_desc = adhoc_new("Globally load module", "http://prosody.im/protocol/modules#global-load", globally_load_module_handler, "global_admin");
local reload_modules_desc = adhoc_new("Reload modules", "http://prosody.im/protocol/modules#reload", reload_modules_handler, "admin");
local globally_reload_module_desc = adhoc_new("Globally reload module", "http://prosody.im/protocol/modules#global-reload", globally_reload_module_handler, "global_admin");
local shut_down_service_desc = adhoc_new("Shut Down Service", "http://jabber.org/protocol/admin#shutdown", shut_down_service_handler, "global_admin");
local unload_modules_desc = adhoc_new("Unload modules", "http://prosody.im/protocol/modules#unload", unload_modules_handler, "admin");
local globally_unload_module_desc = adhoc_new("Globally unload module", "http://prosody.im/protocol/modules#global-unload", globally_unload_module_handler, "global_admin");
local activate_host_desc = adhoc_new("Activate host", "http://prosody.im/protocol/hosts#activate", activate_host_handler, "global_admin");
local deactivate_host_desc = adhoc_new("Deactivate host", "http://prosody.im/protocol/hosts#deactivate", deactivate_host_handler, "global_admin");

module:provides("adhoc", add_user_desc);
module:provides("adhoc", change_user_password_desc);
module:provides("adhoc", config_reload_desc);
module:provides("adhoc", delete_user_desc);
module:provides("adhoc", end_user_session_desc);
module:provides("adhoc", get_user_password_desc);
module:provides("adhoc", get_user_roster_desc);
module:provides("adhoc", get_user_stats_desc);
module:provides("adhoc", get_online_users_desc);
module:provides("adhoc", list_s2s_this_desc);
module:provides("adhoc", list_modules_desc);
module:provides("adhoc", load_module_desc);
module:provides("adhoc", globally_load_module_desc);
module:provides("adhoc", reload_modules_desc);
module:provides("adhoc", globally_reload_module_desc);
module:provides("adhoc", shut_down_service_desc);
module:provides("adhoc", unload_modules_desc);
module:provides("adhoc", globally_unload_module_desc);
module:provides("adhoc", activate_host_desc);
module:provides("adhoc", deactivate_host_desc);
