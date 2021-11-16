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

function is_important(stanza) --> boolean, reason: string
	if stanza == " " then
		return true, "whitespace keepalive";
	elseif type(stanza) == "string" then
		return true, "raw data";
	elseif not st.is_stanza(stanza) then
		-- This should probably never happen
		return true, type(stanza);
	end
	if stanza.attr.xmlns ~= nil then
		-- stream errors, stream management etc
		return true, "nonza";
	end
	local st_name = stanza.name;
	if not st_name then return false; end
	local st_type = stanza.attr.type;
	if st_name == "presence" then
		if st_type == nil or st_type == "unavailable" or st_type == "error" then
			return false, "presence update";
		end
		-- TODO Some MUC awareness, e.g. check for the 'this relates to you' status code
		return true, "subscription request";
	elseif st_name == "message" then
		if st_type == "headline" then
			-- Headline messages are ephemeral by definition
			return false, "headline";
		end
		if st_type == "error" then
			return true, "delivery failure";
		end
		if stanza:get_child("sent", "urn:xmpp:carbons:2") then
			return true, "carbon";
		end
		local forwarded = stanza:find("{urn:xmpp:carbons:2}received/{urn:xmpp:forward:0}/{jabber:client}message");
		if forwarded then
			stanza = forwarded;
		end
		if stanza:get_child("body") then
			return true, "body";
		end
		if stanza:get_child("subject") then
			-- Last step of a MUC join
			return true, "subject";
		end
		if stanza:get_child("encryption", "urn:xmpp:eme:0") then
			-- Since we can't know what an encrypted message contains, we assume it's important
			-- XXX Experimental XEP
			return true, "encrypted";
		end
		if stanza:get_child("x", "jabber:x:conference") or stanza:find("{http://jabber.org/protocol/muc#user}x/invite") then
			return true, "invite";
		end
		if stanza:get_child(nil, "urn:xmpp:jingle-message:0") then
			-- XXX Experimental XEP
			return true, "jingle call";
		end
		for important in important_payloads do
			if stanza:find(important) then
				return true;
			end
		end
		return false;
	elseif st_name == "iq" then
		return true;
	end
end

module:hook("csi-is-stanza-important", function (event)
	local important, why = is_important(event.stanza);
	event.reason = why;
	return important;
end, -1);

local function should_flush(stanza, session, ctr) --> boolean, reason: string
	if ctr >= queue_size then
		return true, "queue size limit reached";
	end
	local event = { stanza = stanza, session = session };
	local ret = module:fire_event("csi-is-stanza-important", event)
	return ret, event.reason;
end

local function with_timestamp(stanza, from)
	if st.is_stanza(stanza) and stanza.attr.xmlns == nil and stanza.name ~= "iq" then
		stanza = st.clone(stanza);
		stanza:add_direct_child(st.stanza("delay", {xmlns = "urn:xmpp:delay", from = from, stamp = dt.datetime()}));
	end
	return stanza;
end

local measure_buffer_hold = module:measure("buffer_hold", "times",
	{ buckets = { 0.1; 1; 5; 10; 15; 30; 60; 120; 180; 300; 600; 900 } });

local flush_reasons = module:metric(
	"counter", "flushes", "",
	"CSI queue flushes",
	{ "reason" }
);

local function manage_buffer(stanza, session)
	local ctr = session.csi_counter or 0;
	local flush, why = should_flush(stanza, session, ctr);
	if flush then
		if session.csi_measure_buffer_hold then
			session.csi_measure_buffer_hold();
			session.csi_measure_buffer_hold = nil;
		end
		flush_reasons:with_labels(why or "important"):add(1);
		session.log("debug", "Flushing buffer (%s; queue size is %d)", why or "important", session.csi_counter);
		session.state = "flushing";
		module:fire_event("csi-flushing", { session = session });
		session.conn:resume_writes();
	else
		session.log("debug", "Holding buffer (%s; queue size is %d)", why or "unimportant", session.csi_counter);
		stanza = with_timestamp(stanza, jid.join(session.username, session.host))
	end
	session.csi_counter = ctr + 1;
	return stanza;
end

local function flush_buffer(data, session)
	session.log("debug", "Flushing buffer (%s; queue size is %d)", "client activity", session.csi_counter);
	flush_reasons:with_labels("client activity"):add(1);
	if session.csi_measure_buffer_hold then
		session.csi_measure_buffer_hold();
		session.csi_measure_buffer_hold = nil;
	end
	session.conn:resume_writes();
	return data;
end

function enable_optimizations(session)
	if session.conn and session.conn.pause_writes then
		session.conn:pause_writes();
		session.csi_measure_buffer_hold = measure_buffer_hold();
		session.csi_counter = 0;
		filters.add_filter(session, "stanzas/out", manage_buffer);
		filters.add_filter(session, "bytes/in", flush_buffer);
	else
		session.log("warn", "Session connection does not support write pausing");
	end
end

function disable_optimizations(session)
	filters.remove_filter(session, "stanzas/out", manage_buffer);
	filters.remove_filter(session, "bytes/in", flush_buffer);
	session.csi_counter = nil;
	if session.csi_measure_buffer_hold then
		session.csi_measure_buffer_hold();
		session.csi_measure_buffer_hold = nil;
	end
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
	if (session.state == "flushing" or session.state == "inactive") and session.conn and session.conn.pause_writes then
		session.state = "inactive";
		session.conn:pause_writes();
		session.csi_measure_buffer_hold = measure_buffer_hold();
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

function module.command(arg)
	if arg[1] ~= "test" then
		print("Usage: "..module.name.." test < test-stream.xml")
		print("");
		print("Provide a series of stanzas to test against importance algorithm");
		return 1;
	end
	-- luacheck: ignore 212/self
	local xmppstream = require "util.xmppstream";
	local input_session = { notopen = true }
	local stream_callbacks = { stream_ns = "jabber:client", default_ns = "jabber:client" };
	function stream_callbacks:handlestanza(stanza)
		local important, because = is_important(stanza);
		print("--");
		print(stanza:indent(nil, "  "));
		-- :pretty_print() maybe?
		if important then
			print((because or "unspecified reason").. " -> important");
		else
			print((because or "unspecified reason").. " -> unimportant");
		end
	end
	local input_stream = xmppstream.new(input_session, stream_callbacks);
	input_stream:reset();
	input_stream:feed(st.stanza("stream", { xmlns = "jabber:client" }):top_tag());
	input_session.notopen = nil;

	for line in io.lines() do
		input_stream:feed(line);
	end
end
