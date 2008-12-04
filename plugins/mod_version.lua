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

local log = require "util.logger".init("mod_version");

local xmlns_version = "jabber:iq:version"

module:add_feature(xmlns_version);

local function handle_version_request(session, stanza)
	if stanza.attr.type == "get" then
		session.send(st.reply(stanza):query(xmlns_version)
			:tag("name"):text("Prosody"):up()
			:tag("version"):text("0.1"):up()
			:tag("os"):text("the best operating system ever!"));
	end
end

module:add_iq_handler("c2s", xmlns_version, handle_version_request);
module:add_iq_handler("s2sin", xmlns_version, handle_version_request);
