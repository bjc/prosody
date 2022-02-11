-- XEP-0198: Stream Management for Prosody IM
--
-- Copyright (C) 2010-2015 Matthew Wild
-- Copyright (C) 2010 Waqas Hussain
-- Copyright (C) 2012-2022 Kim Alvefur
-- Copyright (C) 2012 Thijs Alkemade
-- Copyright (C) 2014 Florian Zeitz
-- Copyright (C) 2016-2020 Thilo Molitor
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- TODO unify sendq and smqueue

local tonumber = tonumber;
local tostring = tostring;
local os_time = os.time;

-- These metrics together allow to calculate an instantaneous
-- "unacked stanzas" metric in the graphing frontend, without us having to
-- iterate over all the queues.
local tx_queued_stanzas = module:measure("tx_queued_stanzas", "counter");
local tx_dropped_stanzas =  module:metric(
	"histogram",
	"tx_dropped_stanzas", "", "number of stanzas in a queue which got dropped",
	{},
	{buckets = {0, 1, 2, 4, 8, 16, 32}}
):with_labels();
local tx_acked_stanzas = module:metric(
	"histogram",
	"tx_acked_stanzas", "", "number of items acked per ack received",
	{},
	{buckets = {0, 1, 2, 4, 8, 16, 32}}
):with_labels();

-- number of session resumptions attempts where the session had expired
local resumption_expired = module:measure("session_resumption_expired", "counter");
local resumption_age = module:metric(
	"histogram",
	"resumption_age", "seconds", "time the session had been hibernating at the time of a resumption",
	{},
	{buckets = { 0, 1, 2, 5, 10, 30, 60, 120, 300, 600 }}
):with_labels();
local sessions_expired = module:measure("sessions_expired", "counter");
local sessions_started = module:measure("sessions_started", "counter");


local datetime = require "util.datetime";
local add_filter = require "util.filters".add_filter;
local jid = require "util.jid";
local smqueue = require "util.smqueue";
local st = require "util.stanza";
local timer = require "util.timer";
local new_id = require "util.id".short;
local watchdog = require "util.watchdog";
local it = require"util.iterators";

local sessionmanager = require "core.sessionmanager";
local core_process_stanza = prosody.core_process_stanza;

local xmlns_errors = "urn:ietf:params:xml:ns:xmpp-stanzas";
local xmlns_delay = "urn:xmpp:delay";
local xmlns_mam2 = "urn:xmpp:mam:2";
local xmlns_sm2 = "urn:xmpp:sm:2";
local xmlns_sm3 = "urn:xmpp:sm:3";

local sm2_attr = { xmlns = xmlns_sm2 };
local sm3_attr = { xmlns = xmlns_sm3 };

local queue_size = module:get_option_number("smacks_max_queue_size", 500);
local resume_timeout = module:get_option_number("smacks_hibernation_time", 600);
local s2s_smacks = module:get_option_boolean("smacks_enabled_s2s", true);
local s2s_resend = module:get_option_boolean("smacks_s2s_resend", false);
local max_unacked_stanzas = module:get_option_number("smacks_max_unacked_stanzas", 0);
local max_inactive_unacked_stanzas = module:get_option_number("smacks_max_inactive_unacked_stanzas", 256);
local delayed_ack_timeout = module:get_option_number("smacks_max_ack_delay", 30);
local max_old_sessions = module:get_option_number("smacks_max_old_sessions", 10);

local c2s_sessions = module:shared("/*/c2s/sessions");
local local_sessions = prosody.hosts[module.host].sessions;

local function format_h(h) if h then return string.format("%d", h) end end

local all_old_sessions = module:open_store("smacks_h");
local old_session_registry = module:open_store("smacks_h", "map");
local session_registry = module:shared "/*/smacks/resumption-tokens"; -- > user@host/resumption-token --> resource

local function track_session(session, id)
	session_registry[jid.join(session.username, session.host, id or session.resumption_token)] = session;
	session.resumption_token = id;
end

local function save_old_session(session)
	session_registry[jid.join(session.username, session.host, session.resumption_token)] = nil;
	return old_session_registry:set(session.username, session.resumption_token,
		{ h = session.handled_stanza_count; t = os.time() })
end

local function clear_old_session(session, id)
	session_registry[jid.join(session.username, session.host, id or session.resumption_token)] = nil;
	return old_session_registry:set(session.username, id or session.resumption_token, nil)
end

local ack_errors = require"util.error".init("mod_smacks", xmlns_sm3, {
	head = { condition = "undefined-condition"; text = "Client acknowledged more stanzas than sent by server" };
	tail = { condition = "undefined-condition"; text = "Client acknowledged less stanzas than already acknowledged" };
	pop = { condition = "internal-server-error"; text = "Something went wrong with Stream Management" };
	overflow = { condition = "resource-constraint", text = "Too many unacked stanzas remaining, session can't be resumed" }
});

-- COMPAT note the use of compatibility wrapper in events (queue:table())

local function ack_delayed(session, stanza)
	-- fire event only if configured to do so and our session is not already hibernated or destroyed
	if delayed_ack_timeout > 0 and session.awaiting_ack
	and not session.hibernating and not session.destroyed then
		session.log("debug", "Firing event 'smacks-ack-delayed', queue = %d",
			session.outgoing_stanza_queue and session.outgoing_stanza_queue:count_unacked() or 0);
		module:fire_event("smacks-ack-delayed", {origin = session, queue = session.outgoing_stanza_queue:table(), stanza = stanza});
	end
	session.delayed_ack_timer = nil;
end

local function can_do_smacks(session, advertise_only)
	if session.smacks then return false, "unexpected-request", "Stream management is already enabled"; end

	local session_type = session.type;
	if session.username then
		if not(advertise_only) and not(session.resource) then -- Fail unless we're only advertising sm
			return false, "unexpected-request", "Client must bind a resource before enabling stream management";
		end
		return true;
	elseif s2s_smacks and (session_type == "s2sin" or session_type == "s2sout") then
		return true;
	end
	return false, "service-unavailable", "Stream management is not available for this stream";
end

module:hook("stream-features",
		function (event)
			if can_do_smacks(event.origin, true) then
				event.features:tag("sm", sm2_attr):tag("optional"):up():up();
				event.features:tag("sm", sm3_attr):tag("optional"):up():up();
			end
		end);

module:hook("s2s-stream-features",
		function (event)
			if can_do_smacks(event.origin, true) then
				event.features:tag("sm", sm2_attr):tag("optional"):up():up();
				event.features:tag("sm", sm3_attr):tag("optional"):up():up();
			end
		end);

local function should_ack(session, force)
	if not session then return end -- shouldn't be possible
	if session.destroyed then return end -- gone
	if not session.smacks then return end -- not using
	if session.hibernating then return end -- can't ack when asleep
	if session.awaiting_ack then return end -- already waiting
	if force then return force end
	local queue = session.outgoing_stanza_queue;
	local expected_h = session.last_acknowledged_stanza + queue:count_unacked();
	local max_unacked = max_unacked_stanzas;
	if session.state == "inactive" then
		max_unacked = max_inactive_unacked_stanzas;
	end
	-- this check of last_requested_h prevents ack-loops if misbehaving clients report wrong
	-- stanza counts. it is set when an <r> is really sent (e.g. inside timer), preventing any
	-- further requests until a higher h-value would be expected.
	return queue:count_unacked() > max_unacked and expected_h ~= session.last_requested_h;
end

local function request_ack(session, reason)
	local queue = session.outgoing_stanza_queue;
	session.log("debug", "Sending <r> (inside timer, before send) from %s - #queue=%d", reason, queue:count_unacked());
	(session.sends2s or session.send)(st.stanza("r", { xmlns = session.smacks }))
	if session.destroyed then return end -- sending something can trigger destruction
	session.awaiting_ack = true;
	-- expected_h could be lower than this expression e.g. more stanzas added to the queue meanwhile)
	session.last_requested_h = session.last_acknowledged_stanza + queue:count_unacked();
	session.log("debug", "Sending <r> (inside timer, after send) from %s - #queue=%d", reason, queue:count_unacked());
	if not session.delayed_ack_timer then
		session.delayed_ack_timer = timer.add_task(delayed_ack_timeout, function()
			ack_delayed(session, nil); -- we don't know if this is the only new stanza in the queue
		end);
	end
end

local function request_ack_now_if_needed(session, force, reason)
	if should_ack(session, force) then
		request_ack(session, reason);
	end
end

local function outgoing_stanza_filter(stanza, session)
	-- XXX: Normally you wouldn't have to check the xmlns for a stanza as it's
	-- supposed to be nil.
	-- However, when using mod_smacks with mod_websocket, then mod_websocket's
	-- stanzas/out filter can get called before this one and adds the xmlns.
	if session.resending_unacked then return stanza end
	if not session.smacks then return stanza end
	local is_stanza = st.is_stanza(stanza) and
		(not stanza.attr.xmlns or stanza.attr.xmlns == 'jabber:client')
		and not stanza.name:find":";

	if is_stanza then
		local queue = session.outgoing_stanza_queue;
		local cached_stanza = st.clone(stanza);

		if cached_stanza.name ~= "iq" and cached_stanza:get_child("delay", xmlns_delay) == nil then
			cached_stanza = cached_stanza:tag("delay", {
				xmlns = xmlns_delay,
				from = jid.bare(session.full_jid or session.host),
				stamp = datetime.datetime()
			});
		end

		queue:push(cached_stanza);
		tx_queued_stanzas(1);

		if session.hibernating then
			session.log("debug", "hibernating since %s, stanza queued", datetime.datetime(session.hibernating));
			-- FIXME queue implementation changed, anything depending on it being an array will break
			module:fire_event("smacks-hibernation-stanza-queued", {origin = session, queue = queue:table(), stanza = cached_stanza});
			return nil;
		end
	end
	return stanza;
end

local function count_incoming_stanzas(stanza, session)
	if not stanza.attr.xmlns then
		session.handled_stanza_count = session.handled_stanza_count + 1;
		session.log("debug", "Handled %d incoming stanzas", session.handled_stanza_count);
	end
	return stanza;
end

local function wrap_session_out(session, resume)
	if not resume then
		session.outgoing_stanza_queue = smqueue.new(queue_size);
		session.last_acknowledged_stanza = 0;
	end

	add_filter(session, "stanzas/out", outgoing_stanza_filter, -999);

	return session;
end

module:hook("pre-session-close", function(event)
	local session = event.session;
	if session.smacks == nil then return end
	if session.resumption_token then
		session.log("debug", "Revoking resumption token");
		clear_old_session(session);
		session.resumption_token = nil;
	else
		session.log("debug", "Session not resumable");
	end
	if session.hibernating_watchdog then
		session.log("debug", "Removing sleeping watchdog");
		-- If the session is being replaced instead of resume, we don't want the
		-- old session around to time out and cause trouble for the new session
		session.hibernating_watchdog:cancel();
		session.hibernating_watchdog = nil;
	else
		session.log("debug", "No watchdog set");
	end
	-- send out last ack as per revision 1.5.2 of XEP-0198
	if session.smacks and session.conn and session.handled_stanza_count then
		(session.sends2s or session.send)(st.stanza("a", {
			xmlns = session.smacks;
			h = format_h(session.handled_stanza_count);
		}));
	end
end);

local function wrap_session_in(session, resume)
	if not resume then
		sessions_started(1);
		session.handled_stanza_count = 0;
	end
	add_filter(session, "stanzas/in", count_incoming_stanzas, 999);

	return session;
end

local function wrap_session(session, resume)
	wrap_session_out(session, resume);
	wrap_session_in(session, resume);
	return session;
end

function handle_enable(session, stanza, xmlns_sm)
	local ok, err, err_text = can_do_smacks(session);
	if not ok then
		session.log("warn", "Failed to enable smacks: %s", err_text); -- TODO: XEP doesn't say we can send error text, should it?
		(session.sends2s or session.send)(st.stanza("failed", { xmlns = xmlns_sm }):tag(err, { xmlns = xmlns_errors}));
		return true;
	end

	if session.username then
		local old_sessions, err = all_old_sessions:get(session.username);
		module:log("debug", "Old sessions: %q", old_sessions)
		if old_sessions then
			local keep, count = {}, 0;
			for token, info in it.sorted_pairs(old_sessions, function(a, b)
				return (old_sessions[a].t or 0) > (old_sessions[b].t or 0);
			end) do
				count = count + 1;
				if count > max_old_sessions then break end
				keep[token] = info;
			end
			all_old_sessions:set(session.username, keep);
		elseif err then
			module:log("error", "Unable to retrieve old resumption counters: %s", err);
		end
	end

	module:log("debug", "Enabling stream management");
	session.smacks = xmlns_sm;

	wrap_session(session, false);

	local resume_max;
	local resume_token;
	local resume = stanza.attr.resume;
	if resume == "true" or resume == "1" then
		resume_token = new_id();
		track_session(session, resume_token);
		resume_max = tostring(resume_timeout);
	end
	(session.sends2s or session.send)(st.stanza("enabled", { xmlns = xmlns_sm, id = resume_token, resume = resume, max = resume_max }));
	return true;
end
module:hook_tag(xmlns_sm2, "enable", function (session, stanza) return handle_enable(session, stanza, xmlns_sm2); end, 100);
module:hook_tag(xmlns_sm3, "enable", function (session, stanza) return handle_enable(session, stanza, xmlns_sm3); end, 100);

module:hook_tag("http://etherx.jabber.org/streams", "features", function(session, stanza)
	if can_do_smacks(session) then
		session.smacks_feature = stanza:get_child("sm", xmlns_sm3) or stanza:get_child("sm", xmlns_sm2);
	end
end);

module:hook("s2sout-established", function (event)
	local session = event.session;
	if not session.smacks_feature then return end

	session.smacks = session.smacks_feature.attr.xmlns;
	wrap_session_out(session, false);
	session.sends2s(st.stanza("enable", { xmlns = session.smacks }));
end);

function handle_enabled(session, stanza, xmlns_sm) -- luacheck: ignore 212/stanza
	module:log("debug", "Enabling stream management");
	session.smacks = xmlns_sm;

	wrap_session_in(session, false);

	-- FIXME Resume?

	return true;
end
module:hook_tag(xmlns_sm2, "enabled", function (session, stanza) return handle_enabled(session, stanza, xmlns_sm2); end, 100);
module:hook_tag(xmlns_sm3, "enabled", function (session, stanza) return handle_enabled(session, stanza, xmlns_sm3); end, 100);

function handle_r(origin, stanza, xmlns_sm) -- luacheck: ignore 212/stanza
	if not origin.smacks then
		module:log("debug", "Received ack request from non-smack-enabled session");
		return;
	end
	module:log("debug", "Received ack request, acking for %d", origin.handled_stanza_count);
	-- Reply with <a>
	(origin.sends2s or origin.send)(st.stanza("a", { xmlns = xmlns_sm, h = format_h(origin.handled_stanza_count) }));
	-- piggyback our own ack request if needed (see request_ack_if_needed() for explanation of last_requested_h)
	request_ack_now_if_needed(origin, false, "piggybacked by handle_r", nil);
	return true;
end
module:hook_tag(xmlns_sm2, "r", function (origin, stanza) return handle_r(origin, stanza, xmlns_sm2); end);
module:hook_tag(xmlns_sm3, "r", function (origin, stanza) return handle_r(origin, stanza, xmlns_sm3); end);

function handle_a(origin, stanza)
	if not origin.smacks then return; end
	origin.awaiting_ack = nil;
	if origin.awaiting_ack_timer then
		timer.stop(origin.awaiting_ack_timer);
		origin.awaiting_ack_timer = nil;
	end
	if origin.delayed_ack_timer then
		timer.stop(origin.delayed_ack_timer)
		origin.delayed_ack_timer = nil;
	end
	-- Remove handled stanzas from outgoing_stanza_queue
	local h = tonumber(stanza.attr.h);
	if not h then
		origin:close{ condition = "invalid-xml"; text = "Missing or invalid 'h' attribute"; };
		return;
	end
	local queue = origin.outgoing_stanza_queue;
	local handled_stanza_count = h-queue:count_acked();
	local acked, err = ack_errors.coerce(queue:ack(h)); -- luacheck: ignore 211/acked
	if err then
		origin.log("warn", "The client says it handled %d new stanzas, but we sent %d :)",
			handled_stanza_count, queue:count_unacked());
		origin.log("debug", "Client h: %d, our h: %d", tonumber(stanza.attr.h), queue:count_acked());
		for i, item in queue._queue:items() do
			origin.log("debug", "Q item %d: %s", i, item);
		end
		origin:close(err);
		return;
	end
	tx_acked_stanzas:sample(handled_stanza_count);

	origin.log("debug", "#queue = %d (acked: %d)", queue:count_unacked(), handled_stanza_count);
	request_ack_now_if_needed(origin, false, "handle_a", nil)
	return true;
end
module:hook_tag(xmlns_sm2, "a", handle_a);
module:hook_tag(xmlns_sm3, "a", handle_a);

local function handle_unacked_stanzas(session)
	local queue = session.outgoing_stanza_queue;
	local unacked = queue:count_unacked()
	if unacked > 0 then
		tx_dropped_stanzas:sample(unacked);
		session.smacks = false; -- Disable queueing
		session.outgoing_stanza_queue = nil;
		for stanza in queue._queue:consume() do
			if not module:fire_event("delivery/failure", { session = session, stanza = stanza }) then
				if stanza.attr.type ~= "error" and stanza.attr.to ~= session.full_jid then
					local reply = st.error_reply(stanza, "cancel", "recipient-unavailable");
					core_process_stanza(session, reply);
				end
			end
		end
	end
end

-- don't send delivery errors for messages which will be delivered by mam later on
-- check if stanza was archived --> this will allow us to send back errors for stanzas not archived
-- because the user configured the server to do so ("no-archive"-setting for one special contact for example)
module:hook("delivery/failure", function(event)
	local session, stanza = event.session, event.stanza;
	-- Only deal with authenticated (c2s) sessions
	if session.username then
		if stanza.name == "message" and stanza.attr.xmlns == nil and
				( stanza.attr.type == "chat" or ( stanza.attr.type or "normal" ) == "normal" ) then
			-- don't store messages in offline store if they are mam results
			local mam_result = stanza:get_child("result", xmlns_mam2);
			if mam_result ~= nil then
				return true; -- stanza already "handled", don't send an error and don't add it to offline storage
			end
			-- do nothing here for normal messages and don't send out "message delivery errors",
			-- because messages are already in MAM at this point (no need to frighten users)
			local stanza_id = stanza:get_child_with_attr("stanza-id", "urn:xmpp:sid:0", "by", jid.bare(session.full_jid));
			stanza_id = stanza_id and stanza_id.attr.id;
			if session.mam_requested and stanza_id ~= nil then
				session.log("debug", "mod_smacks delivery/failure returning true for mam-handled stanza: mam-archive-id=%s", tostring(stanza_id));
				return true; -- stanza handled, don't send an error
			end
			-- store message in offline store, if this client does not use mam *and* was the last client online
			local sessions = local_sessions[session.username] and local_sessions[session.username].sessions or nil;
			if sessions and next(sessions) == session.resource and next(sessions, session.resource) == nil then
				local ok = module:fire_event("message/offline/handle", { origin = session, username = session.username, stanza = stanza });
				session.log("debug", "mod_smacks delivery/failure returning %s for offline-handled stanza", tostring(ok));
				return ok; -- if stanza was handled, don't send an error
			end
		end
	end
end);

module:hook("pre-resource-unbind", function (event)
	local session = event.session;
	if not session.smacks then return end
	if not session.resumption_token then
		local queue = session.outgoing_stanza_queue;
		if queue:count_unacked() > 0 then
			session.log("debug", "Destroying session with %d unacked stanzas", queue:count_unacked());
			handle_unacked_stanzas(session);
		end
		return
	end
	if session.hibernating then return end

	session.hibernating = os_time();
	session.hibernating_watchdog = watchdog.new(resume_timeout, function()
		session.log("debug", "mod_smacks hibernation timeout reached...");
		if session.destroyed then
			session.log("debug", "The session has already been destroyed");
			return
		elseif not session.resumption_token then
			-- This should normally not happen, the watchdog should be canceled from session:close()
			session.log("debug", "The session has already been resumed or replaced");
			return
		end

		session.log("debug", "Destroying session for hibernating too long");
		save_old_session(session);
		session.resumption_token = nil;
		session.resending_unacked = true; -- stop outgoing_stanza_filter from re-queueing anything anymore
		sessionmanager.destroy_session(session, "Hibernating too long");
		sessions_expired(1);
	end);
	if session.conn then
		local conn = session.conn;
		c2s_sessions[conn] = nil;
		session.conn = nil;
		conn:close();
	end
	module:fire_event("smacks-hibernation-start", { origin = session; queue = session.outgoing_stanza_queue:table() });
	return true; -- Postpone destruction for now
end);

local function handle_s2s_destroyed(event)
	local session = event.session;
	local queue = session.outgoing_stanza_queue;
	if queue and queue:count_unacked() > 0 then
		session.log("warn", "Destroying session with %d unacked stanzas", queue:count_unacked());
		if s2s_resend then
			for stanza in queue:consume() do
				module:send(stanza);
			end
			session.outgoing_stanza_queue = nil;
		else
			handle_unacked_stanzas(session);
		end
	end
end

module:hook("s2sout-destroyed", handle_s2s_destroyed);
module:hook("s2sin-destroyed", handle_s2s_destroyed);

local function get_session_id(session)
	return session.id or (tostring(session):match("[a-f0-9]+$"));
end

function handle_resume(session, stanza, xmlns_sm)
	if session.full_jid then
		session.log("warn", "Tried to resume after resource binding");
		session.send(st.stanza("failed", { xmlns = xmlns_sm })
			:tag("unexpected-request", { xmlns = xmlns_errors })
		);
		return true;
	end

	local id = stanza.attr.previd;
	local original_session = session_registry[jid.join(session.username, session.host, id)];
	if not original_session then
		local old_session = old_session_registry:get(session.username, id);
		if old_session then
			session.log("debug", "Tried to resume old expired session with id %s", id);
			session.send(st.stanza("failed", { xmlns = xmlns_sm, h = format_h(old_session.h) })
				:tag("item-not-found", { xmlns = xmlns_errors })
			);
			clear_old_session(session, id);
			resumption_expired(1);
		else
			session.log("debug", "Tried to resume non-existent session with id %s", id);
			session.send(st.stanza("failed", { xmlns = xmlns_sm })
				:tag("item-not-found", { xmlns = xmlns_errors })
			);
		end;
	else
		if original_session.hibernating_watchdog then
			original_session.log("debug", "Letting the watchdog go");
			original_session.hibernating_watchdog:cancel();
			original_session.hibernating_watchdog = nil;
		elseif session.hibernating then
			original_session.log("error", "Hibernating session has no watchdog!")
		end
		-- zero age = was not hibernating yet
		local age = 0;
		if original_session.hibernating then
			local now = os_time();
			age = now - original_session.hibernating;
		end
		session.log("debug", "mod_smacks resuming existing session %s...", get_session_id(original_session));
		original_session.log("debug", "mod_smacks session resumed from %s...", get_session_id(session));
		-- TODO: All this should move to sessionmanager (e.g. session:replace(new_session))
		if original_session.conn then
			original_session.log("debug", "mod_smacks closing an old connection for this session");
			local conn = original_session.conn;
			c2s_sessions[conn] = nil;
			conn:close();
		end

		local migrated_session_log = session.log;
		original_session.ip = session.ip;
		original_session.conn = session.conn;
		original_session.rawsend = session.rawsend;
		original_session.rawsend.session = original_session;
		original_session.rawsend.conn = original_session.conn;
		original_session.send = session.send;
		original_session.send.session = original_session;
		original_session.close = session.close;
		original_session.filter = session.filter;
		original_session.filter.session = original_session;
		original_session.filters = session.filters;
		original_session.send.filter = original_session.filter;
		original_session.stream = session.stream;
		original_session.secure = session.secure;
		original_session.hibernating = nil;
		original_session.resumption_counter = (original_session.resumption_counter or 0) + 1;
		session.log = original_session.log;
		session.type = original_session.type;
		wrap_session(original_session, true);
		-- Inform xmppstream of the new session (passed to its callbacks)
		original_session.stream:set_session(original_session);
		-- Similar for connlisteners
		c2s_sessions[session.conn] = original_session;

		local queue = original_session.outgoing_stanza_queue;
		local h = tonumber(stanza.attr.h);

		original_session.log("debug", "Pre-resumption #queue = %d", queue:count_unacked())
		local acked, err = ack_errors.coerce(queue:ack(h)); -- luacheck: ignore 211/acked

		if not err and not queue:resumable() then
			err = ack_errors.new("overflow");
		end

		if err or not queue:resumable() then
			original_session.send(st.stanza("failed",
				{ xmlns = xmlns_sm; h = format_h(original_session.handled_stanza_count); previd = id }));
			original_session:close(err);
			return false;
		end

		original_session.send(st.stanza("resumed", { xmlns = xmlns_sm,
			h = format_h(original_session.handled_stanza_count), previd = id }));

		-- Ok, we need to re-send any stanzas that the client didn't see
		-- ...they are what is now left in the outgoing stanza queue
		-- We have to use the send of "session" because we don't want to add our resent stanzas
		-- to the outgoing queue again

		session.log("debug", "resending all unacked stanzas that are still queued after resume, #queue = %d", queue:count_unacked());
		-- FIXME Which session is it that the queue filter sees?
		session.resending_unacked = true;
		original_session.resending_unacked = true;
		for _, queued_stanza in queue:resume() do
			session.send(queued_stanza);
		end
		session.resending_unacked = nil;
		original_session.resending_unacked = nil;
		session.log("debug", "all stanzas resent, now disabling send() in this migrated session, #queue = %d", queue:count_unacked());
		function session.send(stanza) -- luacheck: ignore 432
			migrated_session_log("error", "Tried to send stanza on old session migrated by smacks resume (maybe there is a bug?): %s", tostring(stanza));
			return false;
		end
		module:fire_event("smacks-hibernation-end", {origin = session, resumed = original_session, queue = queue:table()});
		original_session.awaiting_ack = nil; -- Don't wait for acks from before the resumption
		request_ack_now_if_needed(original_session, true, "handle_resume", nil);
		resumption_age:sample(age);
	end
	return true;
end
module:hook_tag(xmlns_sm2, "resume", function (session, stanza) return handle_resume(session, stanza, xmlns_sm2); end);
module:hook_tag(xmlns_sm3, "resume", function (session, stanza) return handle_resume(session, stanza, xmlns_sm3); end);

-- Events when it's sensible to request an ack
-- Could experiment with forcing (ignoring max_unacked) <r>, but when and why?
local request_ack_events = {
	["csi-client-active"] = true;
	["csi-flushing"] = false;
	["c2s-pre-ondrain"] = false;
	["s2s-pre-ondrain"] = false;
};

for event_name, force in pairs(request_ack_events) do
	module:hook(event_name, function(event)
		local session = event.session or event.origin;
		request_ack_now_if_needed(session, force, event_name);
	end);
end

local function handle_read_timeout(event)
	local session = event.session;
	if session.smacks then
		if session.awaiting_ack then
			if session.awaiting_ack_timer then
				timer.stop(session.awaiting_ack_timer);
				session.awaiting_ack_timer = nil;
			end
			if session.delayed_ack_timer then
				timer.stop(session.delayed_ack_timer);
				session.delayed_ack_timer = nil;
			end
			return false; -- Kick the session
		end
		request_ack_now_if_needed(session, true, "read timeout");
		return true;
	end
end

module:hook("s2s-read-timeout", handle_read_timeout);
module:hook("c2s-read-timeout", handle_read_timeout);

module:hook_global("server-stopping", function(event)
	if not local_sessions then
		-- not a VirtualHost, no user sessions
		return
	end
	local reason = event.reason;
	-- Close smacks-enabled sessions ourselves instead of letting mod_c2s close
	-- it, which invalidates the smacks session. This allows preserving the
	-- counter value, so it can be communicated to the client when it tries to
	-- resume the lost session after a restart.
	for _, user in pairs(local_sessions) do
		for _, session in pairs(user.sessions) do
			if session.resumption_token then
				if save_old_session(session) then
					session.resumption_token = nil;

					-- Deal with unacked stanzas
					if session.outgoing_stanza_queue then
						handle_unacked_stanzas(session);
					end

					if session.conn then
						session.conn:close()
						session.conn = nil;
						-- Now when mod_c2s gets here, it will immediately destroy the
						-- session since it is unconnected.
					end

					-- And make sure nobody tries to send anything
					session:close{ condition = "system-shutdown", text = reason };
				end
			end
		end
	end
end, -90);
