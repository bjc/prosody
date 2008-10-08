
local st = require "util.stanza";
local send = require "core.sessionmanager".send_to_session;
local usermanager_user_exists = require "core.usermanager".user_exists;
local usermanager_create_user = require "core.usermanager".create_user;

add_iq_handler("c2s", "jabber:iq:register", function (session, stanza)
	if stanza.tags[1].name == "query" then
		local query = stanza.tags[1];
		if stanza.attr.type == "get" then
			local reply = st.reply(stanza);
			reply:tag("query", {xmlns = "jabber:iq:register"})
				:tag("registered"):up()
				:tag("username"):text(session.username):up()
				:tag("password"):up();
			send(session, reply);
		elseif stanza.attr.type == "set" then
			if query.tags[1] and query.tags[1].name == "remove" then
				-- TODO delete user auth data, send iq response, kick all user resources with a <not-authorized/>, delete all user data
				send(session, st.error_reply(stanza, "cancel", "not-allowed"));
			else
				local username = query:child_with_name("username");
				local password = query:child_with_name("password");
				if username and password then
					-- FIXME shouldn't use table.concat
					username = table.concat(username);
					password = table.concat(password);
					if username == session.username then
						if usermanager_create_user(username, password, session.host) then -- password change -- TODO is this the right way?
							send(session, st.reply(stanza));
						else
							-- TODO unable to write file, file may be locked, etc, what's the correct error?
							send(session, st.error_reply(stanza, "wait", "internal-server-error"));
						end
					else
						send(session, st.error_reply(stanza, "modify", "bad-request"));
					end
				else
					send(session, st.error_reply(stanza, "modify", "bad-request"));
				end
			end
		end
	else
		send(session, st.error_reply(stanza, "cancel", "service-unavailable"));
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
			send(session, reply);
		elseif stanza.attr.type == "set" then
			if query.tags[1] and query.tags[1].name == "remove" then
				send(session, st.error_reply(stanza, "auth", "registration-required"));
			else
				local username = query:child_with_name("username");
				local password = query:child_with_name("password");
				if username and password then
					-- FIXME shouldn't use table.concat
					username = table.concat(username);
					password = table.concat(password);
					if usermanager_user_exists(username, session.host) then
						send(session, st.error_reply(stanza, "cancel", "conflict"));
					else
						if usermanager_create_user(username, password, session.host) then
							send(session, st.reply(stanza)); -- user created!
						else
							-- TODO unable to write file, file may be locked, etc, what's the correct error?
							send(session, st.error_reply(stanza, "wait", "internal-server-error"));
						end
					end
				else
					send(session, st.error_reply(stanza, "modify", "not-acceptable"));
				end
			end
		end
	else
		send(session, st.error_reply(stanza, "cancel", "service-unavailable"));
	end;
end);
