-- Prosody IM v0.4
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local st = require "util.stanza";
local t_concat = table.concat;

local sessionmanager = require "core.sessionmanager";
local usermanager = require "core.usermanager";

module:add_feature("jabber:iq:auth");
module:add_event_hook("stream-features", function (session, features)
	if not session.username then features:tag("auth", {xmlns='http://jabber.org/features/iq-auth'}):up(); end
end);

module:add_iq_handler("c2s_unauthed", "jabber:iq:auth", 
		function (session, stanza)
			local username = stanza.tags[1]:child_with_name("username");
			local password = stanza.tags[1]:child_with_name("password");
			local resource = stanza.tags[1]:child_with_name("resource");
			if not (username and password and resource) then
				local reply = st.reply(stanza);
				session.send(reply:query("jabber:iq:auth")
					:tag("username"):up()
					:tag("password"):up()
					:tag("resource"):up());
				return true;			
			else
				username, password, resource = t_concat(username), t_concat(password), t_concat(resource);
				local reply = st.reply(stanza);
				require "core.usermanager"
				if usermanager.validate_credentials(session.host, username, password) then
					-- Authentication successful!
					local success, err = sessionmanager.make_authenticated(session, username);
					if success then
						local err_type, err_msg;
						success, err_type, err, err_msg = sessionmanager.bind_resource(session, resource);
						if not success then
							session.send(st.error_reply(stanza, err_type, err, err_msg));
							return true;
						end
					end
					session.send(st.reply(stanza));
					return true;
				else
					local reply = st.reply(stanza);
					reply.attr.type = "error";
					reply:tag("error", { code = "401", type = "auth" })
						:tag("not-authorized", { xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas" });
					session.send(reply);
					return true;
				end
			end
			
		end);
