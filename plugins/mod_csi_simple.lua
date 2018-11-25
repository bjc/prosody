-- Copyright (C) 2016-2018 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:depends"csi"

local jid = require "util.jid";
local st = require "util.stanza";
local dt = require "util.datetime";
local new_queue = require "util.queue".new;

local function new_pump(output, ...)
	-- luacheck: ignore 212/self
	local q = new_queue(...);
	local flush = true;
	function q:pause()
		flush = false;
	end
	function q:resume()
		flush = true;
		return q:flush();
	end
	local push = q.push;
	function q:push(item)
		local ok = push(self, item);
		if not ok then
			q:flush();
			output(item, self);
		elseif flush then
			return q:flush();
		end
		return true;
	end
	function q:flush()
		local item = self:pop();
		while item do
			output(item, self);
			item = self:pop();
		end
		return true;
	end
	return q;
end

local queue_size = module:get_option_number("csi_queue_size", 256);

module:hook("csi-is-stanza-important", function (event)
	local stanza = event.stanza;
	if not st.is_stanza(stanza) then
		return true;
	end
	local st_name = stanza.name;
	if not st_name then return false; end
	local st_type = stanza.attr.type;
	if st_name == "presence" then
		if st_type == nil or st_type == "unavailable" then
			return false;
		end
		return true;
	elseif st_name == "message" then
		if st_type == "headline" then
			return false;
		end
		local body = stanza:get_child_text("body");
		return body;
	end
	return true;
end, -1);

module:hook("csi-client-inactive", function (event)
	local session = event.origin;
	if session.pump then
		session.pump:pause();
	else
		local bare_jid = jid.join(session.username, session.host);
		local send = session.send;
		session._orig_send = send;
		local pump = new_pump(session.send, queue_size);
		pump:pause();
		session.pump = pump;
		function session.send(stanza)
			if module:fire_event("csi-is-stanza-important", { stanza = stanza, session = session }) then
				pump:flush();
				send(stanza);
			else
				if st.is_stanza(stanza) then
					stanza = st.clone(stanza);
					stanza:add_direct_child(st.stanza("delay", {xmlns = "urn:xmpp:delay", from = bare_jid, stamp = dt.datetime()}));
				end
				pump:push(stanza);
			end
			return true;
		end
	end
end);

module:hook("csi-client-active", function (event)
	local session = event.origin;
	if session.pump then
		session.pump:resume();
	end
end);

