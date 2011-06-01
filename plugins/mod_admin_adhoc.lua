-- Copyright (C) 2009-2010 Florian Zeitz
--
-- This file is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local _G = _G;

local prosody = _G.prosody;
local hosts = prosody.hosts;
local t_concat = table.concat;

require "util.iterators";
local usermanager_user_exists = require "core.usermanager".user_exists;
local usermanager_create_user = require "core.usermanager".create_user;
local usermanager_get_password = require "core.usermanager".get_password;
local usermanager_set_password = require "core.usermanager".set_password;
local is_admin = require "core.usermanager".is_admin;
local rm_load_roster = require "core.rostermanager".load_roster;
local st, jid, uuid = require "util.stanza", require "util.jid", require "util.uuid";
local timer_add_task = require "util.timer".add_task;
local dataforms_new = require "util.dataforms".new;
local array = require "util.array";
local modulemanager = require "modulemanager";

local adhoc_new = module:require "adhoc".new;

function add_user_command_handler(self, data, state)
	local add_user_layout = dataforms_new{
		title = "Adding a User";
		instructions = "Fill out this form to add a user.";

		{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
		{ name = "accountjid", type = "jid-single", required = true, label = "The Jabber ID for the account to be added" };
		{ name = "password", type = "text-private", label = "The password for this account" };
		{ name = "password-verify", type = "text-private", label = "Retype password" };
	};

	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end
		local fields = add_user_layout:data(data.form);
		if not fields.accountjid then
			return { status = "completed", error = { message = "You need to specify a JID." } };
		end
		local username, host, resource = jid.split(fields.accountjid);
		if data.to ~= host then
			return { status = "completed", error = { message = "Trying to add a user on " .. host .. " but command was sent to " .. data.to}};
		end
		if (fields["password"] == fields["password-verify"]) and username and host then
			if usermanager_user_exists(username, host) then
				return { status = "completed", error = { message = "Account already exists" } };
			else
				if usermanager_create_user(username, fields.password, host) then
					module:log("info", "Created new account " .. username.."@"..host);
					return { status = "completed", info = "Account successfully created" };
				else
					return { status = "completed", error = { message = "Failed to write data to disk" } };
				end
			end
		else
			module:log("debug", (fields.accountjid or "<nil>") .. " " .. (fields.password or "<nil>") .. " "
				.. (fields["password-verify"] or "<nil>"));
			return { status = "completed", error = { message = "Invalid data.\nPassword mismatch, or empty username" } };
		end
	else
		return { status = "executing", form = add_user_layout }, "executing";
	end
end

function change_user_password_command_handler(self, data, state)
	local change_user_password_layout = dataforms_new{
		title = "Changing a User Password";
		instructions = "Fill out this form to change a user's password.";

		{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
		{ name = "accountjid", type = "jid-single", required = true, label = "The Jabber ID for this account" };
		{ name = "password", type = "text-private", required = true, label = "The password for this account" };
	};

	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end
		local fields = change_user_password_layout:data(data.form);
		if not fields.accountjid or fields.accountjid == "" or not fields.password then
			return { status = "completed", error = { message = "Please specify username and password" } };
		end
		local username, host, resource = jid.split(fields.accountjid);
		if data.to ~= host then
			return { status = "completed", error = { message = "Trying to change the password of a user on " .. host .. " but command was sent to " .. data.to}};
		end
		if usermanager_user_exists(username, host) and usermanager_set_password(username, fields.password, host) then
			return { status = "completed", info = "Password successfully changed" };
		else
			return { status = "completed", error = { message = "User does not exist" } };
		end
	else
		return { status = "executing", form = change_user_password_layout }, "executing";
	end
end

function delete_user_command_handler(self, data, state)
	local delete_user_layout = dataforms_new{
		title = "Deleting a User";
		instructions = "Fill out this form to delete a user.";

		{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
		{ name = "accountjids", type = "jid-multi", label = "The Jabber ID(s) to delete" };
	};

	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end
		local fields = delete_user_layout:data(data.form);
		local failed = {};
		local succeeded = {};
		for _, aJID in ipairs(fields.accountjids) do
			local username, host, resource = jid.split(aJID);
			if (host == data.to) and  usermanager_user_exists(username, host) and disconnect_user(aJID) and usermanager_create_user(username, nil, host) then
				module:log("debug", "User " .. aJID .. " has been deleted");
				succeeded[#succeeded+1] = aJID;
			else
				module:log("debug", "Tried to delete non-existant user "..aJID);
				failed[#failed+1] = aJID;
			end
		end
		return {status = "completed", info = (#succeeded ~= 0 and
				"The following accounts were successfully deleted:\n"..t_concat(succeeded, "\n").."\n" or "")..
				(#failed ~= 0 and
				"The following accounts could not be deleted:\n"..t_concat(failed, "\n") or "") };
	else
		return { status = "executing", form = delete_user_layout }, "executing";
	end
end

function disconnect_user(match_jid)
	local node, hostname, givenResource = jid.split(match_jid);
	local host = hosts[hostname];
	local sessions = host.sessions[node] and host.sessions[node].sessions;
	for resource, session in pairs(sessions or {}) do
		if not givenResource or (resource == givenResource) then
			module:log("debug", "Disconnecting "..node.."@"..hostname.."/"..resource);
			session:close();
		end
	end
	return true;
end

function end_user_session_handler(self, data, state)
	local end_user_session_layout = dataforms_new{
		title = "Ending a User Session";
		instructions = "Fill out this form to end a user's session.";

		{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
		{ name = "accountjids", type = "jid-multi", label = "The Jabber ID(s) for which to end sessions" };
	};

	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end

		local fields = end_user_session_layout:data(data.form);
		local failed = {};
		local succeeded = {};
		for _, aJID in ipairs(fields.accountjids) do
			local username, host, resource = jid.split(aJID);
			if (host == data.to) and  usermanager_user_exists(username, host) and disconnect_user(aJID) then
				succeeded[#succeeded+1] = aJID;
			else
				failed[#failed+1] = aJID;
			end
		end
		return {status = "completed", info = (#succeeded ~= 0 and
				"The following accounts were successfully disconnected:\n"..t_concat(succeeded, "\n").."\n" or "")..
				(#failed ~= 0 and
				"The following accounts could not be disconnected:\n"..t_concat(failed, "\n") or "") };
	else
		return { status = "executing", form = end_user_session_layout }, "executing";
	end
end

local end_user_session_layout = dataforms_new{
	title = "Ending a User Session";
	instructions = "Fill out this form to end a user's session.";

	{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
	{ name = "accountjids", type = "jid-multi", label = "The Jabber ID(s) for which to end sessions" };
};


function get_user_password_handler(self, data, state)
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

	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end
		local fields = get_user_password_layout:data(data.form);
		if not fields.accountjid then
			return { status = "completed", error = { message = "Please specify a JID." } };
		end
		local user, host, resource = jid.split(fields.accountjid);
		local accountjid = "";
		local password = "";
		if host ~= data.to then
			return { status = "completed", error = { message = "Tried to get password for a user on " .. host .. " but command was sent to " .. data.to } };
		elseif usermanager_user_exists(user, host) then
			accountjid = fields.accountjid;
			password = usermanager_get_password(user, host);
		else
			return { status = "completed", error = { message = "User does not exist" } };
		end
		return { status = "completed", result = { layout = get_user_password_result_layout, values = {accountjid = accountjid, password = password} } };
	else
		return { status = "executing", form = get_user_password_layout }, "executing";
	end
end

function get_user_roster_handler(self, data, state)
	local get_user_roster_layout = dataforms_new{
		{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
		{ name = "accountjid", type = "jid-single", required = true, label = "The Jabber ID for which to retrieve the roster" };
	};

	local get_user_roster_result_layout = dataforms_new{
		{ name = "FORM_TYPE", type = "hidden", value = "http://jabber.org/protocol/admin" };
		{ name = "accountjid", type = "jid-single", label = "This is the roster for" };
		{ name = "roster", type = "text-multi", label = "Roster XML" };
	};

	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end

		local fields = get_user_roster_layout:data(data.form);

		if not fields.accountjid then
			return { status = "completed", error = { message = "Please specify a JID" } };
		end

		local user, host, resource = jid.split(fields.accountjid);
		if host ~= data.to then
			return { status = "completed", error = { message = "Tried to get roster for a user on " .. host .. " but command was sent to " .. data.to } };
		elseif not usermanager_user_exists(user, host) then
			return { status = "completed", error = { message = "User does not exist" } };
		end
		local roster = rm_load_roster(user, host);

		local query = st.stanza("query", { xmlns = "jabber:iq:roster" });
		for jid in pairs(roster) do
			if jid ~= "pending" and jid then
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

		local query_text = query:__tostring(); -- TODO: Use upcoming pretty_print() function
		query_text = query_text:gsub("><", ">\n<");

		local result = get_user_roster_result_layout:form({ accountjid = user.."@"..host, roster = query_text }, "result");
		result:add_child(query);
		return { status = "completed", other = result };
	else
		return { status = "executing", form = get_user_roster_layout }, "executing";
	end
end

function get_user_stats_handler(self, data, state)
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

	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end

		local fields = get_user_stats_layout:data(data.form);

		if not fields.accountjid then
			return { status = "completed", error = { message = "Please specify a JID." } };
		end

		local user, host, resource = jid.split(fields.accountjid);
		if host ~= data.to then
			return { status = "completed", error = { message = "Tried to get stats for a user on " .. host .. " but command was sent to " .. data.to } };
		elseif not usermanager_user_exists(user, host) then
			return { status = "completed", error = { message = "User does not exist" } };
		end
		local roster = rm_load_roster(user, host);
		local rostersize = 0;
		local IPs = "";
		local resources = "";
		for jid in pairs(roster) do
			if jid ~= "pending" and jid then
				rostersize = rostersize + 1;
			end
		end
		for resource, session in pairs((hosts[host].sessions[user] and hosts[host].sessions[user].sessions) or {}) do
			resources = resources .. "\n" .. resource;
			IPs = IPs .. "\n" .. session.ip;
		end
		return { status = "completed", result = {layout = get_user_stats_result_layout, values = {ipaddresses = IPs, rostersize = tostring(rostersize),
			onlineresources = resources}} };
	else
		return { status = "executing", form = get_user_stats_layout }, "executing";
	end
end

function get_online_users_command_handler(self, data, state)
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

	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end

		local fields = get_online_users_layout:data(data.form);

		local max_items = nil
		if fields.max_items ~= "all" then
			max_items = tonumber(fields.max_items);
		end
		local count = 0;
		local users = {};
		for username, user in pairs(hosts[data.to].sessions or {}) do
			if (max_items ~= nil) and (count >= max_items) then
				break;
			end
			users[#users+1] = username.."@"..data.to;
			count = count + 1;
			if fields.details then
				for resource, session in pairs(user.sessions or {}) do
					local status, priority = "unavailable", tostring(session.priority or "-");
					if session.presence then
						status = session.presence:child_with_name("show");
						if status then
							status = status:get_text() or "[invalid!]";
						else
							status = "available";
						end
					end
					users[#users+1] = " - "..resource..": "..status.."("..priority..")";
				end
			end
		end
		return { status = "completed", result = {layout = get_online_users_result_layout, values = {onlineuserjids=t_concat(users, "\n")}} };
	else
		return { status = "executing", form = get_online_users_layout }, "executing";
	end
end

function list_modules_handler(self, data, state)
	local result = dataforms_new {
		title = "List of loaded modules";

		{ name = "FORM_TYPE", type = "hidden", value = "http://prosody.im/protocol/modules#list" };
		{ name = "modules", type = "text-multi", label = "The following modules are loaded:" };
	};

	local modules = array.collect(keys(hosts[data.to].modules)):sort():concat("\n");

	return { status = "completed", result = { layout = result; values = { modules = modules } } };
end

function load_module_handler(self, data, state)
	local layout = dataforms_new {
		title = "Load module";
		instructions = "Specify the module to be loaded";

		{ name = "FORM_TYPE", type = "hidden", value = "http://prosody.im/protocol/modules#load" };
		{ name = "module", type = "text-single", required = true, label = "Module to be loaded:"};
	};
	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end
		local fields = layout:data(data.form);
		if (not fields.module) or (fields.module == "") then
			return { status = "completed", error = {
				message = "Please specify a module."
			} };
		end
		if modulemanager.is_loaded(data.to, fields.module) then
			return { status = "completed", info = "Module already loaded" };
		end
		local ok, err = modulemanager.load(data.to, fields.module);
		if ok then
			return { status = "completed", info = 'Module "'..fields.module..'" successfully loaded on host "'..data.to..'".' };
		else
			return { status = "completed", error = { message = 'Failed to load module "'..fields.module..'" on host "'..data.to..
			'". Error was: "'..tostring(err or "<unspecified>")..'"' } };
		end
	else
		local modules = array.collect(keys(hosts[data.to].modules)):sort();
		return { status = "executing", form = layout }, "executing";
	end
end

function reload_modules_handler(self, data, state)
	local layout = dataforms_new {
		title = "Reload modules";
		instructions = "Select the modules to be reloaded";

		{ name = "FORM_TYPE", type = "hidden", value = "http://prosody.im/protocol/modules#reload" };
		{ name = "modules", type = "list-multi", required = true, label = "Modules to be reloaded:"};
	};
	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end
		local fields = layout:data(data.form);
		if #fields.modules == 0 then
			return { status = "completed", error = {
				message = "Please specify a module. (This means your client misbehaved, as this field is required)"
			} };
		end
		local ok_list, err_list = {}, {};
		for _, module in ipairs(fields.modules) do
			local ok, err = modulemanager.reload(data.to, module);
			if ok then
				ok_list[#ok_list + 1] = module;
			else
				err_list[#err_list + 1] = module .. "(Error: " .. tostring(err) .. ")";
			end
		end
		local info = (#ok_list > 0 and ("The following modules were successfully reloaded on host "..data.to..":\n"..t_concat(ok_list, "\n")) or "")..
			(#err_list > 0 and ("Failed to reload the following modules on host "..data.to..":\n"..t_concat(err_list, "\n")) or "");
		return { status = "completed", info = info };
	else
		local modules = array.collect(keys(hosts[data.to].modules)):sort();
		return { status = "executing", form = { layout = layout; values = { modules = modules } } }, "executing";
	end
end

function send_to_online(message, server)
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

function shut_down_service_handler(self, data, state)
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

	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end

		local fields = shut_down_service_layout:data(data.form);

		if fields.announcement and #fields.announcement > 0 then
			local message = st.message({type = "headline"}, fields.announcement):up()
				:tag("subject"):text("Server is shutting down");
			send_to_online(message);
		end

		timer_add_task(tonumber(fields.delay or "5"), prosody.shutdown);

		return { status = "completed", info = "Server is about to shut down" };
	else
		return { status = "executing", form = shut_down_service_layout }, "executing";
	end

	return true;
end

function unload_modules_handler(self, data, state)
	local layout = dataforms_new {
		title = "Unload modules";
		instructions = "Select the modules to be unloaded";

		{ name = "FORM_TYPE", type = "hidden", value = "http://prosody.im/protocol/modules#unload" };
		{ name = "modules", type = "list-multi", required = true, label = "Modules to be unloaded:"};
	};
	if state then
		if data.action == "cancel" then
			return { status = "canceled" };
		end
		local fields = layout:data(data.form);
		if #fields.modules == 0 then
			return { status = "completed", error = {
				message = "Please specify a module. (This means your client misbehaved, as this field is required)"
			} };
		end
		local ok_list, err_list = {}, {};
		for _, module in ipairs(fields.modules) do
			local ok, err = modulemanager.unload(data.to, module);
			if ok then
				ok_list[#ok_list + 1] = module;
			else
				err_list[#err_list + 1] = module .. "(Error: " .. tostring(err) .. ")";
			end
		end
		local info = (#ok_list > 0 and ("The following modules were successfully unloaded on host "..data.to..":\n"..t_concat(ok_list, "\n")) or "")..
			(#err_list > 0 and ("Failed to unload the following modules on host "..data.to..":\n"..t_concat(err_list, "\n")) or "");
		return { status = "completed", info = info };
	else
		local modules = array.collect(keys(hosts[data.to].modules)):sort();
		return { status = "executing", form = { layout = layout; values = { modules = modules } } }, "executing";
	end
end

local add_user_desc = adhoc_new("Add User", "http://jabber.org/protocol/admin#add-user", add_user_command_handler, "admin");
local change_user_password_desc = adhoc_new("Change User Password", "http://jabber.org/protocol/admin#change-user-password", change_user_password_command_handler, "admin");
local delete_user_desc = adhoc_new("Delete User", "http://jabber.org/protocol/admin#delete-user", delete_user_command_handler, "admin");
local end_user_session_desc = adhoc_new("End User Session", "http://jabber.org/protocol/admin#end-user-session", end_user_session_handler, "admin");
local get_user_password_desc = adhoc_new("Get User Password", "http://jabber.org/protocol/admin#get-user-password", get_user_password_handler, "admin");
local get_user_roster_desc = adhoc_new("Get User Roster","http://jabber.org/protocol/admin#get-user-roster", get_user_roster_handler, "admin");
local get_user_stats_desc = adhoc_new("Get User Statistics","http://jabber.org/protocol/admin#user-stats", get_user_stats_handler, "admin");
local get_online_users_desc = adhoc_new("Get List of Online Users", "http://jabber.org/protocol/admin#get-online-users", get_online_users_command_handler, "admin");
local list_modules_desc = adhoc_new("List loaded modules", "http://prosody.im/protocol/modules#list", list_modules_handler, "admin");
local load_module_desc = adhoc_new("Load module", "http://prosody.im/protocol/modules#load", load_module_handler, "admin");
local reload_modules_desc = adhoc_new("Reload modules", "http://prosody.im/protocol/modules#reload", reload_modules_handler, "admin");
local shut_down_service_desc = adhoc_new("Shut Down Service", "http://jabber.org/protocol/admin#shutdown", shut_down_service_handler, "admin");
local unload_modules_desc = adhoc_new("Unload modules", "http://prosody.im/protocol/modules#unload", unload_modules_handler, "admin");

module:add_item("adhoc", add_user_desc);
module:add_item("adhoc", change_user_password_desc);
module:add_item("adhoc", delete_user_desc);
module:add_item("adhoc", end_user_session_desc);
module:add_item("adhoc", get_user_password_desc);
module:add_item("adhoc", get_user_roster_desc);
module:add_item("adhoc", get_user_stats_desc);
module:add_item("adhoc", get_online_users_desc);
module:add_item("adhoc", list_modules_desc);
module:add_item("adhoc", load_module_desc);
module:add_item("adhoc", reload_modules_desc);
module:add_item("adhoc", shut_down_service_desc);
module:add_item("adhoc", unload_modules_desc);
