-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local st = require "prosody.util.stanza";
local usermanager_set_password = require "prosody.core.usermanager".set_password;
local usermanager_delete_user = require "prosody.core.usermanager".delete_user;
local nodeprep = require "prosody.util.encodings".stringprep.nodeprep;
local jid_bare = require "prosody.util.jid".bare;

local compat = module:get_option_boolean("registration_compat", true);

module:add_feature("jabber:iq:register");

-- Password change and account deletion handler
local function handle_registration_stanza(event)
	local session, stanza = event.origin, event.stanza;
	local log = session.log or module._log;

	local query = stanza.tags[1];
	if stanza.attr.type == "get" then
		local reply = st.reply(stanza);
		reply:tag("query", {xmlns = "jabber:iq:register"})
			:tag("registered"):up()
			:tag("username"):text(session.username):up()
			:tag("password"):up();
		session.send(reply);
	else -- stanza.attr.type == "set"
		if query.tags[1] and query.tags[1].name == "remove" then
			local username, host = session.username, session.host;

			-- This one weird trick sends a reply to this stanza before the user is deleted
			local old_session_close = session.close;
			session.close = function(self, ...)
				self.send(st.reply(stanza));
				return old_session_close(self, ...);
			end

			local ok, err = usermanager_delete_user(username, host);

			if not ok then
				log("debug", "Removing user account %s@%s failed: %s", username, host, err);
				session.close = old_session_close;
				session.send(st.error_reply(stanza, "cancel", "service-unavailable", err));
				return true;
			end

			log("info", "User removed their account: %s@%s", username, host);
			module:fire_event("user-deregistered", { username = username, host = host, source = "mod_register", session = session });
		else
			local username = query:get_child_text("username");
			local password = query:get_child_text("password");
			if username and password then
				username = nodeprep(username);
				if username == session.username then
					if usermanager_set_password(username, password, session.host, session.resource) then
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
	return true;
end

module:hook("iq/self/jabber:iq:register:query", handle_registration_stanza);
if compat then
	module:hook("iq/host/jabber:iq:register:query", function (event)
		local session, stanza = event.origin, event.stanza;
		if session.type == "c2s" and jid_bare(stanza.attr.to) == session.host then
			return handle_registration_stanza(event);
		end
	end);
end

