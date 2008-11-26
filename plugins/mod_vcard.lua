
require "util.datamanager"
local datamanager = datamanager;

local st = require "util.stanza"
local t_concat, t_insert = table.concat, table.insert;

require "util.jid"
local jid_split = jid.split;

require "core.discomanager".set("vcard", "vcard-temp");

add_iq_handler({"c2s", "s2sin"}, "vcard-temp", 
		function (session, stanza)
			if stanza.tags[1].name == "vCard" then
				local to = stanza.attr.to;
				if stanza.attr.type == "get" then
					local vCard;
					if to then
						local node, host = jid_split(to);
						if hosts[host] and hosts[host].type == "local" then
							vCard = st.deserialize(datamanager.load(node, host, "vCard")); -- load vCard for user or server
						end
					else
						vCard = st.deserialize(datamanager.load(session.username, session.host, "vCard"));-- load user's own vCard
					end
					if vCard then
						session.send(st.reply(stanza):add_child(vCard)); -- send vCard!
					else
						session.send(st.error_reply(stanza, "cancel", "item-not-found"));
					end
				elseif stanza.attr.type == "set" then
					if not to or to == session.username.."@"..session.host then
						if datamanager.store(session.username, session.host, "vCard", st.preserialize(stanza.tags[1])) then
							session.send(st.reply(stanza));
						else
							-- TODO unable to write file, file may be locked, etc, what's the correct error?
							session.send(st.error_reply(stanza, "wait", "internal-server-error"));
						end
					else
						session.send(st.error_reply(stanza, "auth", "forbidden"));
					end
				end
				return true;
			end
		end);

local feature_vcard_attr = { var='vcard-temp' };
add_event_hook("stream-features", 
					function (session, features)												
						if session.type == "c2s" then
							features:tag("feature", feature_vcard_attr):up();
						end
					end);
