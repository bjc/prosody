
local st = require "util.stanza"
local send = require "core.sessionmanager".send_to_session

local jid_split = require "util.jid".split;
local t_concat = table.concat;

local rm_remove_from_roster = require "core.rostermanager".remove_from_roster;
local rm_roster_push = require "core.rostermanager".roster_push;

add_iq_handler("c2s", "jabber:iq:roster", 
		function (session, stanza)
			if stanza.tags[1].name == "query" then
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
				elseif stanza.attr.type == "set" then
					local query = stanza.tags[1];
					if #query.tags == 1 and query.tags[1].name == "item"
							and query.tags[1].attr.xmlns == "jabber:iq:roster" and query.tags[1].attr.jid then
						local item = query.tags[1];
						local from_node, from_host = jid_split(stanza.attr.from);
						local node, host, resource = jid_split(item.attr.jid);
						if not resource then
							if item.attr.jid ~= from_node.."@"..from_host then
								if item.attr.subscription == "remove" then
									if session.roster[item.attr.jid] then
										local success, err_type, err_cond, err_msg = rm_remove_from_roster(session, item.attr.jid);
										if success then
											send(session, st.reply(stanza));
											rm_roster_push(from_node, from_host, item.attr.jid);
										else
											send(session, st.error_reply(stanza, err_type, err_cond, err_msg));
										end
									else
										send(session, st.error_reply(stanza, "modify", "item-not-found"));
									end
								else
									local r_item = {name = item.attr.name, groups = {}};
									if r_item.name == "" then r_item.name = nil; end
									if session.roster[item.attr.jid] then
										r_item.subscription = session.roster[item.attr.jid];
									else
										r_item.subscription = "none";
									end
									for _, child in ipairs(item) do	
										if child.name == "group" then
											local text = t_concat(child);
											if text and text ~= "" then
												r_item.groups[text] = true;
											end
										end
									end
									local success, err_type, err_cond, err_msg = rm_add_to_roster(session, item.attr.jid, r_item);
									if success then
										send(session, st.reply(stanza));
										rm_roster_push(from_node, from_host, item.attr.jid);
									else
										send(session, st.error_reply(stanza, err_type, err_cond, err_msg));
									end
								end
							else
								send(session, st.error_reply(stanza, "cancel", "not-allowed"));
							end
						else
							send(session, st.error_reply(stanza, "modify", "bad-request")); -- FIXME what's the correct error?
						end
					else
						send(session, st.error_reply(stanza, "modify", "bad-request"));
					end
					return true;
				end
			end
		end);