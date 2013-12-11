-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";

module:add_feature("urn:xmpp:ping");

local function ping_handler(event)
	if event.stanza.attr.type == "get" then
		event.origin.send(st.reply(event.stanza));
		return true;
	end
end

module:hook("iq/bare/urn:xmpp:ping:ping", ping_handler);
module:hook("iq/host/urn:xmpp:ping:ping", ping_handler);

-- Ad-hoc command

local datetime = require "util.datetime".datetime;

function ping_command_handler (self, data, state)
	local now = datetime();
	return { info = "Pong\n"..now, status = "completed" };
end

local adhoc_new = module:require "adhoc".new;
local descriptor = adhoc_new("Ping", "ping", ping_command_handler);
module:add_item ("adhoc", descriptor);

