-- Prosody IM v0.2
-- Copyright (C) 2008 Matthew Wild
-- Copyright (C) 2008 Waqas Hussain
-- 
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- as published by the Free Software Foundation; either version 2
-- of the License, or (at your option) any later version.
-- 
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- 
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
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
