-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local hosts = _G.hosts;
local st = require "util.stanza";
local config = require "core.configmanager";
local datamanager = require "util.datamanager";
local usermanager_user_exists = require "core.usermanager".user_exists;
local usermanager_create_user = require "core.usermanager".create_user;
local datamanager_store = require "util.datamanager".store;
local os_time = os.time;
local nodeprep = require "util.encodings".stringprep.nodeprep;

module:add_feature("jabber:iq:register");

module:add_iq_handler("c2s", "jabber:iq:register", function (session, stanza)
	if stanza.tags[1].name == "query" then
		local query = stanza.tags[1];
		if stanza.attr.type == "get" then
			local reply = st.reply(stanza);
			reply:tag("query", {xmlns = "jabber:iq:register"})
				:tag("registered"):up()
				:tag("username"):text(session.username):up()
				:tag("password"):up();
			session.send(reply);
		elseif stanza.attr.type == "set" then
			if query.tags[1] and query.tags[1].name == "remove" then
				-- TODO delete user auth data, send iq response, kick all user resources with a <not-authorized/>, delete all user data
				local username, host = session.username, session.host;
				--session.send(st.error_reply(stanza, "cancel", "not-allowed"));
				--return;
				usermanager_create_user(username, nil, host); -- Disable account
				-- FIXME the disabling currently allows a different user to recreate the account
				-- we should add an in-memory account block mode when we have threading
				session.send(st.reply(stanza));
				local roster = session.roster;
				for _, session in pairs(hosts[host].sessions[username].sessions) do -- disconnect all resources
					session:close({condition = "not-authorized", text = "Account deleted"});
				end
				-- TODO datamanager should be able to delete all user data itself
				datamanager.store(username, host, "roster", nil);
				datamanager.store(username, host, "vcard", nil);
				datamanager.store(username, host, "private", nil);
				datamanager.store(username, host, "offline", nil);
				--local bare = username.."@"..host;
				for jid, item in pairs(roster) do
					if jid ~= "pending" then
						if item.subscription == "both" or item.subscription == "to" then
							-- TODO unsubscribe
						end
						if item.subscription == "both" or item.subscription == "from" then
							-- TODO unsubscribe
						end
					end
				end
				datamanager.store(username, host, "accounts", nil); -- delete accounts datastore at the end
				module:log("info", "User removed their account: %s@%s", username, host);
				module:fire_event("user-deregistered", { username = username, host = host, source = "mod_register", session = session });
			else
				local username = query:child_with_name("username");
				local password = query:child_with_name("password");
				if username and password then
					-- FIXME shouldn't use table.concat
					username = nodeprep(table.concat(username));
					password = table.concat(password);
					if username == session.username then
						if usermanager_create_user(username, password, session.host) then -- password change -- TODO is this the right way?
							session.send(st.reply(stanza));
						else
							-- TODO unable to write file, file may be locked, etc, what's the correct error?
							session.send(st.error_reply(stanza, "wait", "internal-server-error"));
						end
					else
						session.send(st.error_reply(stanza, "modify", "bad-request"));
					end
				else
					session.send(st.error_reply(stanza, "modify", "bad-request"));
				end
			end
		end
	else
		session.send(st.error_reply(stanza, "cancel", "service-unavailable"));
	end;
end);

local recent_ips = {};
local min_seconds_between_registrations = config.get(module.host, "core", "min_seconds_between_registrations");
local whitelist_only = config.get(module.host, "core", "whitelist_registration_only");
local whitelisted_ips = config.get(module.host, "core", "registration_whitelist") or { "127.0.0.1" };
local blacklisted_ips = config.get(module.host, "core", "registration_blacklist") or {};

for _, ip in ipairs(whitelisted_ips) do whitelisted_ips[ip] = true; end
for _, ip in ipairs(blacklisted_ips) do blacklisted_ips[ip] = true; end

module:add_iq_handler("c2s_unauthed", "jabber:iq:register", function (session, stanza)
	if config.get(module.host, "core", "allow_registration") == false then
		session.send(st.error_reply(stanza, "cancel", "service-unavailable"));
	elseif stanza.tags[1].name == "query" then
		local query = stanza.tags[1];
		if stanza.attr.type == "get" then
			local reply = st.reply(stanza);
			reply:tag("query", {xmlns = "jabber:iq:register"})
				:tag("instructions"):text("Choose a username and password for use with this service."):up()
				:tag("username"):up()
				:tag("password"):up();
			session.send(reply);
		elseif stanza.attr.type == "set" then
			if query.tags[1] and query.tags[1].name == "remove" then
				session.send(st.error_reply(stanza, "auth", "registration-required"));
			else
				local username = query:child_with_name("username");
				local password = query:child_with_name("password");
				if username and password then
					-- Check that the user is not blacklisted or registering too often
					if blacklisted_ips[session.ip] or (whitelist_only and not whitelisted_ips[session.ip]) then
							session.send(st.error_reply(stanza, "cancel", "not-acceptable"));
							return;
					elseif min_seconds_between_registrations and not whitelisted_ips[session.ip] then
						if not recent_ips[session.ip] then
							recent_ips[session.ip] = { time = os_time(), count = 1 };
						else
						
							local ip = recent_ips[session.ip];
							ip.count = ip.count + 1;
							
							if os_time() - ip.time < min_seconds_between_registrations then
								ip.time = os_time();
								session.send(st.error_reply(stanza, "wait", "not-acceptable"));
								return;
							end
							ip.time = os_time();
						end
					end
					-- FIXME shouldn't use table.concat
					username = nodeprep(table.concat(username));
					password = table.concat(password);
					local host = module.host;
					if not username then
						session.send(st.error_reply(stanza, "modify", "not-acceptable"));
					elseif usermanager_user_exists(username, host) then
						session.send(st.error_reply(stanza, "cancel", "conflict"));
					else
						if usermanager_create_user(username, password, host) then
							session.send(st.reply(stanza)); -- user created!
							module:log("info", "User account created: %s@%s", username, host);
							module:fire_event("user-registered", { 
								username = username, host = host, source = "mod_register",
								session = session });
						else
							-- TODO unable to write file, file may be locked, etc, what's the correct error?
							session.send(st.error_reply(stanza, "wait", "internal-server-error"));
						end
					end
				else
					session.send(st.error_reply(stanza, "modify", "not-acceptable"));
				end
			end
		end
	else
		session.send(st.error_reply(stanza, "cancel", "service-unavailable"));
	end;
end);

