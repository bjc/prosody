
local st = require "util.stanza"
local send = require "core.sessionmanager".send_to_session

add_iq_handler("c2s", "jabber:iq:roster", 
		function (session, stanza)
			if stanza.attr.type == "get" then
				session.roster = session.roster or rostermanager.getroster(session.username, session.host);
				if session.roster == false then
					send(session, st.reply(stanza)
						:tag("error", { type = "wait" })
						:tag("internal-server-error", { xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"}));
					return true;
				else session.roster = session.roster or {};
				end
				local roster = st.reply(stanza)
							:query("jabber:iq:roster");
				for jid in pairs(session.roster) do
					roster:tag("item", { jid = jid, subscription = "none" }):up();
				end
				send(session, roster);
				return true;
			end
		end);