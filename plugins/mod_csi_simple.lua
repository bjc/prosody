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
local filters = require "util.filters";

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
		if stanza:get_child("sent", "urn:xmpp:carbons:2") then
			return true;
		end
		local forwarded = stanza:find("{urn:xmpp:carbons:2}received/{urn:xmpp:forward:0}/{jabber:client}message");
		if forwarded then
			stanza = forwarded;
		end
		if stanza:get_child("body") then
			return true;
		end
		if stanza:get_child("subject") then
			return true;
		end
		if stanza:get_child("encryption", "urn:xmpp:eme:0") then
			return true;
		end
		return false;
	end
	return true;
end, -1);

local function with_timestamp(stanza, from)
	if st.is_stanza(stanza) and stanza.attr.xmlns == nil and stanza.name ~= "iq" then
		stanza = st.clone(stanza);
		stanza:add_direct_child(st.stanza("delay", {xmlns = "urn:xmpp:delay", from = from, stamp = dt.datetime()}));
	end
	return stanza;
end

local function manage_buffer(stanza, session)
	local ctr = session.csi_counter or 0;
	if ctr >= queue_size or module:fire_event("csi-is-stanza-important", { stanza = stanza, session = session }) then
		session.conn:resume_writes();
	else
		stanza = with_timestamp(stanza, jid.join(session.username, session.host))
	end
	session.csi_counter = ctr + 1;
	return stanza;
end

local function flush_buffer(data, session)
	session.conn:resume_writes();
	return data;
end

module:hook("csi-client-inactive", function (event)
	local session = event.origin;
	if session.conn and session.conn and session.conn.pause_writes then
		session.conn:pause_writes();
		filters.add_filter(session, "stanzas/out", manage_buffer);
		filters.add_filter(session, "bytes/in", flush_buffer);
	elseif session.pump then
		session.pump:pause();
	else
		local bare_jid = jid.join(session.username, session.host);
		local send = session.send;
		session._orig_send = send;
		local pump = new_pump(session.send, queue_size);
		pump:pause();
		session.pump = pump;
		function session.send(stanza)
			if session.state == "active" or module:fire_event("csi-is-stanza-important", { stanza = stanza, session = session }) then
				pump:flush();
				send(stanza);
			else
				pump:push(with_timestamp(stanza, bare_jid));
			end
			return true;
		end
	end
end);

module:hook("csi-client-active", function (event)
	local session = event.origin;
	if session.pump then
		session.pump:resume();
	elseif session.conn and session.conn and session.conn.resume_writes then
		filters.remove_filter(session, "stanzas/out", manage_buffer);
		filters.remove_filter(session, "bytes/in", flush_buffer);
		session.conn:resume_writes();
	end
end);


module:hook("c2s-ondrain", function (event)
	local session = event.session;
	if session.state == "inactive" and session.conn and session.conn and session.conn.pause_writes then
		session.csi_counter = 0;
		session.conn:pause_writes();
	end
end);
