-- XEP-0280: Message Carbons implementation for Prosody
-- Copyright (C) 2011-2016 Kim Alvefur
--
-- This file is MIT/X11 licensed.

local st = require "util.stanza";
local jid_bare = require "util.jid".bare;
local jid_resource = require "util.jid".resource;
local xmlns_carbons = "urn:xmpp:carbons:2";
local xmlns_forward = "urn:xmpp:forward:0";
local full_sessions, bare_sessions = prosody.full_sessions, prosody.bare_sessions;

local function is_bare(jid)
	return not jid_resource(jid);
end

local function toggle_carbons(event)
	local origin, stanza = event.origin, event.stanza;
	local state = stanza.tags[1].name;
	module:log("debug", "%s %sd carbons", origin.full_jid, state);
	origin.want_carbons = state == "enable" and stanza.tags[1].attr.xmlns;
	origin.send(st.reply(stanza));
	return true;
end
module:hook("iq-set/self/"..xmlns_carbons..":disable", toggle_carbons);
module:hook("iq-set/self/"..xmlns_carbons..":enable", toggle_carbons);

local function should_copy(stanza, c2s, user_bare) --> boolean, reason: string
	local st_type = stanza.attr.type or "normal";
	if stanza:get_child("private", xmlns_carbons) then
		return false, "private";
	end

	if stanza:get_child("no-copy", "urn:xmpp:hints") then
		return false, "hint";
	end

	if not c2s and stanza.attr.to ~= user_bare and stanza:get_child("x", "http://jabber.org/protocol/muc#user") then
		-- MUC PMs are normally sent to full JIDs
		return false, "muc-pm";
	end

	if st_type == "chat" then
		return true, "type";
	end

	if st_type == "normal" and stanza:get_child("body") then
		return true, "type";
	end

	-- Normal outgoing chat messages are sent to=bare JID. This clause should
	-- match the error bounces from those, which would have from=bare JID and
	-- be incoming (not c2s).
	if st_type == "error" and not c2s and is_bare(stanza.attr.from) then
		return true, "bounce";
	end

	for archived in stanza:childtags("stanza-id", "urn:xmpp:sid:0") do
		if archived and archived.attr.by == user_bare then
			return true, "archived";
		end
	end

	return false, "default";
end

local function message_handler(event, c2s)
	local origin, stanza = event.origin, event.stanza;
	local orig_type = stanza.attr.type or "normal";
	local orig_from = stanza.attr.from;
	local bare_from = jid_bare(orig_from);
	local orig_to = stanza.attr.to;
	local bare_to = jid_bare(orig_to);

	-- Stanza sent by a local client
	local bare_jid = bare_from; -- JID of the local user
	local target_session = origin;
	local top_priority = false;
	local user_sessions = bare_sessions[bare_from];

	-- Stanza about to be delivered to a local client
	if not c2s then
		bare_jid = bare_to;
		target_session = full_sessions[orig_to];
		user_sessions = bare_sessions[bare_jid];
		if not target_session and user_sessions then
			-- The top resources will already receive this message per normal routing rules,
			-- so we are going to skip them in order to avoid sending duplicated messages.
			local top_resources = user_sessions.top_resources;
			top_priority = top_resources and top_resources[1].priority
		end
	end

	if not user_sessions then
		module:log("debug", "Skip carbons for offline user");
		return -- No use in sending carbons to an offline user
	end

	local should, why = should_copy(stanza, c2s, bare_jid);

	if not should then
		module:log("debug", "Not copying stanza: %s (%s)", stanza:top_tag(), why);
		if why == "private" and not c2s then
			stanza:maptags(function(tag)
				if not ( tag.attr.xmlns == xmlns_carbons and tag.name == "private" ) then
					return tag;
				end
			end);
		end
		return;
	end

	local carbon;
	user_sessions = user_sessions and user_sessions.sessions;
	for _, session in pairs(user_sessions) do
		-- Carbons are sent to resources that have enabled it
		if session.want_carbons
		-- but not the resource that sent the message, or the one that it's directed to
		and session ~= target_session
		-- and isn't among the top resources that would receive the message per standard routing rules
		and (c2s or session.priority ~= top_priority) then
			if not carbon then
				-- Create the carbon copy and wrap it as per the Stanza Forwarding XEP
				local copy = st.clone(stanza);
				if c2s and not orig_to then
					stanza.attr.to = bare_from;
				end
				copy.attr.xmlns = "jabber:client";
				carbon = st.message{ from = bare_jid, type = orig_type, }
					:tag(c2s and "sent" or "received", { xmlns = xmlns_carbons })
						:tag("forwarded", { xmlns = xmlns_forward })
							:add_child(copy):reset();

			end

			carbon.attr.to = session.full_jid;
			module:log("debug", "Sending carbon to %s", session.full_jid);
			session.send(carbon);
		end
	end
end

local function c2s_message_handler(event)
	return message_handler(event, true)
end

-- Stanzas sent by local clients
module:hook("pre-message/host", c2s_message_handler, -0.5);
module:hook("pre-message/bare", c2s_message_handler, -0.5);
module:hook("pre-message/full", c2s_message_handler, -0.5);
-- Stanzas to local clients
module:hook("message/bare", message_handler, -0.5);
module:hook("message/full", message_handler, -0.5);

module:add_feature(xmlns_carbons);
