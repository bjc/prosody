
local st = require "util.stanza"
local send = require "core.sessionmanager".send_to_session

add_iq_handler("c2s", "jabber:iq:roster", 
		function (session, stanza)
			if stanza.attr.type == "get" then
				local roster = st.reply(stanza)
							:query("jabber:iq:roster");
				for jid in pairs(session.roster) do
					roster:tag("item", { jid = jid, subscription = "none" }):up();
				end
				send(session, roster);
				return true;
			end
		end);