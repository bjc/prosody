
local st = require "util.stanza";
local send = require "core.sessionmanager".send_to_session;
local t_concat = table.concat;

add_iq_handler("c2s_unauthed", "jabber:iq:auth", 
		function (session, stanza)
			local username = stanza.tags[1]:child_with_name("username");
			local password = stanza.tags[1]:child_with_name("password");
			local resource = stanza.tags[1]:child_with_name("resource");
			if not (username and password and resource) then
				local reply = st.reply(stanza);
				send(session, reply:query("jabber:iq:auth")
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
						success, err = sessionmanager.bind_resource(session, resource);
						--FIXME: Reply with error
						if not success then
							local reply = st.reply(stanza);
							reply.attr.type = "error";
							if err == "conflict" then
								reply:tag("error", { code = "409", type = "cancel" })
									:tag("conflict", { xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas" });
							elseif err == "constraint" then
								reply:tag("error", { code = "409", type = "cancel" })
									:tag("already-bound", { xmlns = "x-lxmppd:extensions:legacyauth" });
							elseif err == "auth" then
								reply:tag("error", { code = "401", type = "auth" })
									:tag("not-authorized", { xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas" });
							end
							send(session, reply);
							return true;
						end
					end
					send(session, st.reply(stanza));
					return true;
				else
					local reply = st.reply(stanza);
					reply.attr.type = "error";
					reply:tag("error", { code = "401", type = "auth" })
						:tag("not-authorized", { xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas" });
					dispatch_stanza(reply);
					return true;
				end
			end
			
		end);