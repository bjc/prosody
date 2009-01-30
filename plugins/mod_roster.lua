-- Prosody IM v0.2
-- Copyright (C) 2008 Matthew Wild
-- Copyright (C) 2008 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local st = require "util.stanza"

local jid_split = require "util.jid".split;
local t_concat = table.concat;

local handle_presence = require "core.presencemanager".handle_presence;
local rm_remove_from_roster = require "core.rostermanager".remove_from_roster;
local rm_add_to_roster = require "core.rostermanager".add_to_roster;
local rm_roster_push = require "core.rostermanager".roster_push;
local core_route_stanza = core_route_stanza;

module:add_feature("jabber:iq:roster");

module:add_iq_handler("c2s", "jabber:iq:roster", 
		function (session, stanza)
			if stanza.tags[1].name == "query" then
				if stanza.attr.type == "get" then
					local roster = st.reply(stanza)
								:query("jabber:iq:roster");
					for jid in pairs(session.roster) do
						if jid ~= "pending" then
							roster:tag("item", {
								jid = jid,
								subscription = session.roster[jid].subscription,
								ask = session.roster[jid].ask,
								name = session.roster[jid].name,
							});
							for group in pairs(session.roster[jid].groups) do
								roster:tag("group"):text(group):up();
							end
							roster:up(); -- move out from item
						end
					end
					session.send(roster);
					session.interested = true; -- resource is interested in roster updates
					return true;
				elseif stanza.attr.type == "set" then
					local query = stanza.tags[1];
					if #query.tags == 1 and query.tags[1].name == "item"
							and query.tags[1].attr.xmlns == "jabber:iq:roster" and query.tags[1].attr.jid
							and query.tags[1].attr.jid ~= "pending" then
						local item = query.tags[1];
						local from_node, from_host = jid_split(stanza.attr.from);
						local from_bare = from_node and (from_node.."@"..from_host) or from_host; -- bare JID
						local node, host, resource = jid_split(item.attr.jid);
						local to_bare = node and (node.."@"..host) or host; -- bare JID
						if not resource and host then
							if item.attr.jid ~= from_node.."@"..from_host then
								if item.attr.subscription == "remove" then
									local r_item = session.roster[item.attr.jid];
									if r_item then
										local success, err_type, err_cond, err_msg = rm_remove_from_roster(session, item.attr.jid);
										if success then
											session.send(st.reply(stanza));
											rm_roster_push(from_node, from_host, item.attr.jid);
											if r_item.subscription == "both" or r_item.subscription == "from" then
												handle_presence(session, st.presence({type="unsubscribed"}), from_bare, to_bare,
													core_route_stanza, false);
											elseif r_item.subscription == "both" or r_item.subscription == "to" then
												handle_presence(session, st.presence({type="unsubscribe"}), from_bare, to_bare,
													core_route_stanza, false);
											end
										else
											session.send(st.error_reply(stanza, err_type, err_cond, err_msg));
										end
									else
										session.send(st.error_reply(stanza, "modify", "item-not-found"));
									end
								else
									local r_item = {name = item.attr.name, groups = {}};
									if r_item.name == "" then r_item.name = nil; end
									if session.roster[item.attr.jid] then
										r_item.subscription = session.roster[item.attr.jid].subscription;
										r_item.ask = session.roster[item.attr.jid].ask;
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
										session.send(st.reply(stanza));
										rm_roster_push(from_node, from_host, item.attr.jid);
									else
										session.send(st.error_reply(stanza, err_type, err_cond, err_msg));
									end
								end
							else
								session.send(st.error_reply(stanza, "cancel", "not-allowed"));
							end
						else
							session.send(st.error_reply(stanza, "modify", "bad-request")); -- FIXME what's the correct error?
						end
					else
						session.send(st.error_reply(stanza, "modify", "bad-request"));
					end
					return true;
				end
			end
		end);
