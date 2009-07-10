-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local st = require "util.stanza";
local datamanager = require "util.datamanager";

module:hook("iq/bare/jabber:iq:privacy:query", function(data)
	local origin, stanza = data.origin, data.stanza;
	
	if not stanza.attr.to then -- only service requests to own bare JID
		local query = stanza.tags[1]; -- the query element
		local privacy_lists = datamanager.load(origin.username, origin.host, "privacy") or {};
		if stanza.attr.type == "set" then
			-- TODO
		elseif stanza.attr.type == "get" then
			if #query.tags == 0 then -- Client requests names of privacy lists from server
				-- TODO
			elseif #query.tags == 1 and query.tags[1].name == "list" then -- Client requests a privacy list from server
				-- TODO
			else
				origin.send(st.error_reply(stanza, "modify", "bad-request"));
			end
		end
	end
end);
