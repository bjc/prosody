
local st = require "util.stanza";
local usermanager_user_exists = require "core.usermanager".user_exists;
local usermanager_create_user = require "core.usermanager".create_user;
local datamanager_store = require "util.datamanager".store;

add_iq_handler("c2s", "jabber:iq:register", function (session, stanza)
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
				--session.send(st.error_reply(stanza, "cancel", "not-allowed"));
				--return;
				usermanager_create_user(session.username, nil, session.host); -- Disable account
				-- FIXME the disabling currently allows a different user to recreate the account
				-- we should add an in-memory account block mode when we have threading
				session.send(st.reply(stanza));
				local roster = session.roster;
				for _, session in pairs(hosts[session.host].sessions[session.username].sessions) do -- disconnect all resources
					session:disconnect({condition = "not-authorized", text = "Account deleted"});
				end
				-- TODO datamanager should be able to delete all user data itself
				datamanager.store(session.username, session.host, "roster", nil);
				datamanager.store(session.username, session.host, "vCard", nil);
				datamanager.store(session.username, session.host, "private", nil);
				datamanager.store(session.username, session.host, "offline", nil);
				local bare = session.username.."@"..session.host;
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
				datamanager.store(session.username, session.host, "accounts", nil); -- delete accounts datastore at the end
			else
				local username = query:child_with_name("username");
				local password = query:child_with_name("password");
				if username and password then
					-- FIXME shouldn't use table.concat
					username = table.concat(username);
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

add_iq_handler("c2s_unauthed", "jabber:iq:register", function (session, stanza)
	if stanza.tags[1].name == "query" then
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
					-- FIXME shouldn't use table.concat
					username = table.concat(username);
					password = table.concat(password);
					if usermanager_user_exists(username, session.host) then
						session.send(st.error_reply(stanza, "cancel", "conflict"));
					else
						if usermanager_create_user(username, password, session.host) then
							session.send(st.reply(stanza)); -- user created!
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
