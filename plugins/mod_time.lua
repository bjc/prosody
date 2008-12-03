-- Prosody IM v0.1
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



local st = require "util.stanza";
local datetime = require "util.datetime".datetime;
local legacy = require "util.datetime".legacy;

-- XEP-0202: Entity Time

require "core.discomanager".set("time", "urn:xmpp:time");

module:add_iq_handler({"c2s", "s2sin"}, "urn:xmpp:time",
	function(session, stanza)
		if stanza.attr.type == "get" then
			session.send(st.reply(stanza):tag("time", {xmlns="urn:xmpp:time"})
				:tag("tzo"):text("+00:00"):up() -- FIXME get the timezone in a platform independent fashion
				:tag("utc"):text(datetime()));
		end
	end);

-- XEP-0090: Entity Time (deprecated)

require "core.discomanager".set("time", "jabber:iq:time");

module:add_iq_handler({"c2s", "s2sin"}, "jabber:iq:time",
	function(session, stanza)
		if stanza.attr.type == "get" then
			session.send(st.reply(stanza):tag("query", {xmlns="jabber:iq:time"})
				:tag("utc"):text(legacy()));
		end
	end);
