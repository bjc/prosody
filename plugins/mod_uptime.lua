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

local start_time = os.time();

module:add_feature("jabber:iq:last");

module:add_iq_handler({"c2s", "s2sin"}, "jabber:iq:last", 
	function (origin, stanza)
		if stanza.tags[1].name == "query" then
			if stanza.attr.type == "get" then
				local node, host, resource = jid_split(stanza.attr.to);
				if node or resource then
					-- TODO
				else
					origin.send(st.reply(stanza):tag("query", {xmlns = "jabber:iq:last", seconds = tostring(os.difftime(os.time(), start_time))}));
					return true;
				end
			end
		end
	end);
