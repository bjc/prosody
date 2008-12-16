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



local st = require "util.stanza";

--local sessions = sessions;

local t_insert = table.insert;

local log = require "util.logger".init("mod_starttls");

local xmlns_starttls ='urn:ietf:params:xml:ns:xmpp-tls';

module:add_handler("c2s_unauthed", "starttls", xmlns_starttls,
		function (session, stanza)
			if session.conn.starttls then
				session.send(st.stanza("proceed", { xmlns = xmlns_starttls }));
				session:reset_stream();
				session.conn.starttls();
				session.log("info", "TLS negotiation started...");
			else
				-- FIXME: What reply?
				session.log("warn", "Attempt to start TLS, but TLS is not available on this connection");
			end
		end);
		
local starttls_attr = { xmlns = xmlns_starttls };
module:add_event_hook("stream-features", 
					function (session, features)												
						if session.conn.starttls then
							features:tag("starttls", starttls_attr):up();
						end
					end);
