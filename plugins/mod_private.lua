
local st = require "util.stanza"
local send = require "core.sessionmanager".send_to_session

local jid_split = require "util.jid".split;
local datamanager = require "util.datamanager"

add_iq_handler("c2s", "jabber:iq:private",
	function (session, stanza)
		local type = stanza.attr.type;
		local query = stanza.tags[1];
		if (type == "get" or type == "set") and query.name == "query" then
			local node, host = jid_split(stanza.attr.to);
			if not(node or host) or (node == session.username and host == session.host) then
				node, host = session.username, session.host;
				if #query.tags == 1 then
					local tag = query.tags[1];
					local key = tag.name..":"..tag.attr.xmlns;
					local data = datamanager.load(node, host, "private");
					if stanza.attr.type == "get" then
						if data and data[key] then
							send(session, st.reply(stanza):tag("query", {xmlns = "jabber:iq:private"}):add_child(st.deserialize(data[key])));
						else
							send(session, st.reply(stanza):add_child(stanza.tags[1]));
						end
					else -- set
						if not data then data = {}; end;
						if #tag == 0 then
							data[key] = nil;
						else
							data[key] = st.preserialize(tag);
						end
						-- TODO delete datastore if empty
						if datamanager.store(node, host, "private", data) then
							send(session, st.reply(stanza));
						else
							send(session, st.error_reply(stanza, "wait", "internal-server-error"));
						end
					end
				else
					send(session, st.error_reply(stanza, "modify", "bad-format"));
				end
			else
				send(session, st.error_reply(stanza, "cancel", "forbidden"));
			end
		end
	end);