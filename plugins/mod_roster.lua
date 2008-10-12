
local st = require "util.stanza"
local send = require "core.sessionmanager".send_to_session

add_iq_handler("c2s", "jabber:iq:roster", 
		function (session, stanza)
			if stanza.attr.type == "get" then
				local roster = st.reply(stanza)
							:query("jabber:iq:roster");
				for jid in pairs(session.roster) do
					local item = st.stanza("item", {
						jid = jid,
						subscription = session.roster[jid].subscription,
						name = session.roster[jid].name,
					});
					for group in pairs(session.roster[jid].groups) do
						item:tag("group"):text(group):up();
					end
					roster:add_child(item);
				end
				send(session, roster);
				return true;
			end
		end);