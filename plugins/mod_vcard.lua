-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local hosts = _G.hosts;
local datamanager = require "util.datamanager"

local st = require "util.stanza"
local t_concat, t_insert = table.concat, table.insert;

local jid = require "util.jid"
local jid_split = jid.split;

local xmlns_vcard = "vcard-temp";

module:add_feature(xmlns_vcard);

function handle_vcard(session, stanza)
	if stanza.tags[1].name == "vCard" then
		local to = stanza.attr.to;
		if stanza.attr.type == "get" then
			local vCard;
			if to then
				local node, host = jid_split(to);
				if hosts[host] and hosts[host].type == "local" then
					vCard = st.deserialize(datamanager.load(node, host, "vcard")); -- load vCard for user or server
				end
			else
				vCard = st.deserialize(datamanager.load(session.username, session.host, "vcard"));-- load user's own vCard
			end
			if vCard then
				session.send(st.reply(stanza):add_child(vCard)); -- send vCard!
			else
				session.send(st.error_reply(stanza, "cancel", "item-not-found"));
			end
		elseif stanza.attr.type == "set" then
			if not to or to == session.username.."@"..session.host then
				if datamanager.store(session.username, session.host, "vcard", st.preserialize(stanza.tags[1])) then
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
end

module:add_iq_handler({"c2s", "s2sin", "component"}, xmlns_vcard, handle_vcard);

-- COMPAT: https://support.process-one.net/browse/EJAB-1045
if module:get_option("vcard_compatibility") then
	module:hook("iq/full", function (data)
		local stanza = data.stanza;
		if stanza.attr.type == "get" and stanza.tags[1]
			and stanza.tags[1].attr.xmlns == xmlns_vcard then
				return handle_vcard(data.origin, stanza);
		end
	end, 1);
end

local feature_vcard_attr = { var=xmlns_vcard };
module:add_event_hook("stream-features",
					function (session, features)
						if session.type == "c2s" then
							features:tag("feature", feature_vcard_attr):up();
						end
					end);
