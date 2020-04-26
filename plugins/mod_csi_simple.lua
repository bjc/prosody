-- Copyright (C) 2016-2020 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:depends"csi"

local jid = require "util.jid";
local st = require "util.stanza";
local dt = require "util.datetime";
local filters = require "util.filters";

local queue_size = module:get_option_number("csi_queue_size", 256);

local important_payloads = module:get_option_set("csi_important_payloads", { });

module:hook("csi-is-stanza-important", function (event)
	local stanza = event.stanza;
	if not st.is_stanza(stanza) then
		-- whitespace pings etc
		return true;
	end
	if stanza.attr.xmlns ~= nil then
		-- stream errors, stream management etc
		return true;
	end
	local st_name = stanza.name;
	if not st_name then return false; end
	local st_type = stanza.attr.type;
	if st_type == "error" then
		return true;
	end
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
		if stanza:get_child("x", "jabber:x:conference") or stanza:find("{http://jabber.org/protocol/muc#user}x/invite") then
			return true;
		end
		for important in important_payloads do
			if stanza:find(important) then
				return true;
			end
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
	if ctr >= queue_size then
		session.log("debug", "Queue size limit hit, flushing buffer (queue size is %d)", session.csi_counter);
		session.conn:resume_writes();
	elseif module:fire_event("csi-is-stanza-important", { stanza = stanza, session = session }) then
		session.log("debug", "Important stanza, flushing buffer (queue size is %d)", session.csi_counter);
		session.conn:resume_writes();
	else
		stanza = with_timestamp(stanza, jid.join(session.username, session.host))
	end
	session.csi_counter = ctr + 1;
	return stanza;
end

local function flush_buffer(data, session)
	if session.csi_flushing then
		return data;
	end
	session.csi_flushing = true;
	session.log("debug", "Client sent something, flushing buffer once (queue size is %d)", session.csi_counter);
	session.conn:resume_writes();
	return data;
end

function enable_optimizations(session)
	if session.conn and session.conn.pause_writes then
		session.conn:pause_writes();
		filters.add_filter(session, "stanzas/out", manage_buffer);
		filters.add_filter(session, "bytes/in", flush_buffer);
	else
		session.log("warn", "Session connection does not support write pausing");
	end
end

function disable_optimizations(session)
	session.csi_flushing = nil;
	filters.remove_filter(session, "stanzas/out", manage_buffer);
	filters.remove_filter(session, "bytes/in", flush_buffer);
	if session.conn and session.conn.resume_writes then
		session.conn:resume_writes();
	end
end

module:hook("csi-client-inactive", function (event)
	local session = event.origin;
	enable_optimizations(session);
end);

module:hook("csi-client-active", function (event)
	local session = event.origin;
	disable_optimizations(session);
end);

module:hook("pre-resource-unbind", function (event)
	local session = event.session;
	disable_optimizations(session);
end, 1);

module:hook("c2s-ondrain", function (event)
	local session = event.session;
	if session.state == "inactive" and session.conn and session.conn.pause_writes then
		session.conn:pause_writes();
		session.log("debug", "Buffer flushed, resuming inactive mode (queue size was %d)", session.csi_counter);
		session.csi_counter = 0;
	end
end);

function module.load()
	for _, user_session in pairs(prosody.hosts[module.host].sessions) do
		for _, session in pairs(user_session.sessions) do
			if session.state == "inactive" then
				enable_optimizations(session);
			end
		end
	end
end

function module.unload()
	for _, user_session in pairs(prosody.hosts[module.host].sessions) do
		for _, session in pairs(user_session.sessions) do
			if session.state == "inactive" then
				disable_optimizations(session);
			end
		end
	end
end
