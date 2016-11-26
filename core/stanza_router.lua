-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local log = require "util.logger".init("stanzarouter")

local hosts = _G.prosody.hosts;
local tostring = tostring;
local st = require "util.stanza";
local jid_split = require "util.jid".split;
local jid_prepped_split = require "util.jid".prepped_split;

local full_sessions = _G.prosody.full_sessions;
local bare_sessions = _G.prosody.bare_sessions;

local core_post_stanza, core_process_stanza, core_route_stanza;

function deprecated_warning(f)
	_G[f] = function(...)
		log("warn", "Using the global %s() is deprecated, use module:send() or prosody.%s(). %s", f, f, debug.traceback());
		return prosody[f](...);
	end
end
deprecated_warning"core_post_stanza";
deprecated_warning"core_process_stanza";
deprecated_warning"core_route_stanza";

local valid_stanzas = { message = true, presence = true, iq = true };
local function handle_unhandled_stanza(host, origin, stanza) --luacheck: ignore 212/host
	local name, xmlns, origin_type = stanza.name, stanza.attr.xmlns or "jabber:client", origin.type;
	if xmlns == "jabber:client" and valid_stanzas[name] then
		-- A normal stanza
		local st_type = stanza.attr.type;
		if st_type == "error" or (name == "iq" and st_type == "result") then
			if st_type == "error" then
				local err_type, err_condition, err_message = stanza:get_error();
				log("debug", "Discarding unhandled error %s (%s, %s) from %s: %s", name, err_type, err_condition or "unknown condition", origin_type, stanza:top_tag());
			else
				log("debug", "Discarding %s from %s of type: %s", name, origin_type, st_type or '<nil>');
			end
			return;
		end
		if name == "iq" and (st_type == "get" or st_type == "set") and stanza.tags[1] then
			xmlns = stanza.tags[1].attr.xmlns or "jabber:client";
		end
		log("debug", "Unhandled %s stanza: %s; xmlns=%s", origin_type, name, xmlns);
		if origin.send then
			origin.send(st.error_reply(stanza, "cancel", "service-unavailable"));
		end
	else
		log("warn", "Unhandled %s stream element or stanza: %s; xmlns=%s: %s", origin_type, name, xmlns, tostring(stanza)); -- we didn't handle it
		origin:close("unsupported-stanza-type");
	end
end

local iq_types = { set=true, get=true, result=true, error=true };
function core_process_stanza(origin, stanza)
	(origin.log or log)("debug", "Received[%s]: %s", origin.type, stanza:top_tag())

	if origin.type == "c2s" and not stanza.attr.xmlns then
		local name, st_type = stanza.name, stanza.attr.type;
		if st_type == "error" and #stanza.tags == 0 then
			return handle_unhandled_stanza(origin.host, origin, stanza);
		end
		if name == "iq" then
			if not iq_types[st_type] then
				origin.send(st.error_reply(stanza, "modify", "bad-request", "Invalid IQ type"));
				return;
			elseif not stanza.attr.id then
				origin.send(st.error_reply(stanza, "modify", "bad-request", "Missing required 'id' attribute"));
				return;
			elseif (st_type == "set" or st_type == "get") and (#stanza.tags ~= 1) then
				origin.send(st.error_reply(stanza, "modify", "bad-request", "Incorrect number of children for IQ stanz"));
				return;
			end
		end

		if not origin.full_jid
			and not(name == "iq" and st_type == "set" and stanza.tags[1] and stanza.tags[1].name == "bind"
					and stanza.tags[1].attr.xmlns == "urn:ietf:params:xml:ns:xmpp-bind") then
			-- authenticated client isn't bound and current stanza is not a bind request
			if stanza.attr.type ~= "result" and stanza.attr.type ~= "error" then
				origin.send(st.error_reply(stanza, "auth", "not-authorized")); -- FIXME maybe allow stanzas to account or server
			end
			return;
		end

		-- TODO also, stanzas should be returned to their original state before the function ends
		stanza.attr.from = origin.full_jid;
	end
	local to, xmlns = stanza.attr.to, stanza.attr.xmlns;
	local from = stanza.attr.from;
	local node, host, resource;
	local from_node, from_host, from_resource;
	local to_bare, from_bare;
	if to then
		if full_sessions[to] or bare_sessions[to] or hosts[to] then
			node, host = jid_split(to); -- TODO only the host is needed, optimize
		else
			node, host, resource = jid_prepped_split(to);
			if not host then
				log("warn", "Received stanza with invalid destination JID: %s", to);
				if stanza.attr.type ~= "error" and stanza.attr.type ~= "result" then
					origin.send(st.error_reply(stanza, "modify", "jid-malformed", "The destination address is invalid: "..to));
				end
				return;
			end
			to_bare = node and (node.."@"..host) or host; -- bare JID
			if resource then to = to_bare.."/"..resource; else to = to_bare; end
			stanza.attr.to = to;
		end
	end
	if from and not origin.full_jid then
		-- We only stamp the 'from' on c2s stanzas, so we still need to check validity
		from_node, from_host, from_resource = jid_prepped_split(from);
		if not from_host then
			log("warn", "Received stanza with invalid source JID: %s", from);
			if stanza.attr.type ~= "error" and stanza.attr.type ~= "result" then
				origin.send(st.error_reply(stanza, "modify", "jid-malformed", "The source address is invalid: "..from));
			end
			return;
		end
		from_bare = from_node and (from_node.."@"..from_host) or from_host; -- bare JID
		if from_resource then from = from_bare.."/"..from_resource; else from = from_bare; end
		stanza.attr.from = from;
	end

	if (origin.type == "s2sin" or origin.type == "c2s" or origin.type == "component") and xmlns == nil then
		if origin.type == "s2sin" and not origin.dummy then
			local host_status = origin.hosts[from_host];
			if not host_status or not host_status.authed then -- remote server trying to impersonate some other server?
				log("warn", "Received a stanza claiming to be from %s, over a stream authed for %s!", from_host, origin.from_host);
				origin:close("not-authorized");
				return;
			elseif not hosts[host] then
				log("warn", "Remote server %s sent us a stanza for %s, closing stream", origin.from_host, host);
				origin:close("host-unknown");
				return;
			end
		end
		core_post_stanza(origin, stanza, origin.full_jid);
	else
		local h = hosts[stanza.attr.to or origin.host or origin.to_host];
		if h then
			local event;
			if xmlns == nil then
				if stanza.name == "iq" and (stanza.attr.type == "set" or stanza.attr.type == "get") then
					event = "stanza/iq/"..stanza.tags[1].attr.xmlns..":"..stanza.tags[1].name;
				else
					event = "stanza/"..stanza.name;
				end
			else
				event = "stanza/"..xmlns..":"..stanza.name;
			end
			if h.events.fire_event(event, {origin = origin, stanza = stanza}) then return; end
		end
		if host and not hosts[host] then host = nil; end -- COMPAT: workaround for a Pidgin bug which sets 'to' to the SRV result
		handle_unhandled_stanza(host or origin.host or origin.to_host, origin, stanza);
	end
end

function core_post_stanza(origin, stanza, preevents)
	local to = stanza.attr.to;
	local node, host, resource = jid_split(to);
	local to_bare = node and (node.."@"..host) or host; -- bare JID

	local to_type, to_self;
	if node then
		if resource then
			to_type = '/full';
		else
			to_type = '/bare';
			if node == origin.username and host == origin.host then
				stanza.attr.to = nil;
				to_self = true;
			end
		end
	else
		if host then
			to_type = '/host';
		else
			to_type = '/bare';
			to_self = true;
		end
	end

	local event_data = {origin=origin, stanza=stanza};
	if preevents then -- c2s connection
		if hosts[origin.host].events.fire_event('pre-'..stanza.name..to_type, event_data) then return; end -- do preprocessing
	end
	local h = hosts[to_bare] or hosts[host or origin.host];
	if h then
		if h.events.fire_event(stanza.name..to_type, event_data) then return; end -- do processing
		if to_self and h.events.fire_event(stanza.name..'/self', event_data) then return; end -- do processing
		handle_unhandled_stanza(h.host, origin, stanza);
	else
		core_route_stanza(origin, stanza);
	end
end

function core_route_stanza(origin, stanza)
	local node, host, resource = jid_split(stanza.attr.to);
	local from_node, from_host, from_resource = jid_split(stanza.attr.from);

	-- Auto-detect origin if not specified
	origin = origin or hosts[from_host];
	if not origin then return false; end

	if hosts[host] then
		-- old stanza routing code removed
		core_post_stanza(origin, stanza);
	else
		log("debug", "Routing to remote...");
		local host_session = hosts[from_host];
		if not host_session then
			log("error", "No hosts[from_host] (please report): %s", tostring(stanza));
		else
			local xmlns = stanza.attr.xmlns;
			stanza.attr.xmlns = nil;
			local routed = host_session.events.fire_event("route/remote", { origin = origin, stanza = stanza, from_host = from_host, to_host = host });
			stanza.attr.xmlns = xmlns; -- reset
			if not routed then
				log("debug", "... no, just kidding.");
				if stanza.attr.type == "error" or (stanza.name == "iq" and stanza.attr.type == "result") then return; end
				core_route_stanza(host_session, st.error_reply(stanza, "cancel", "not-allowed", "Communication with remote domains is not enabled"));
			end
		end
	end
end

--luacheck: ignore 122/prosody
prosody.core_process_stanza = core_process_stanza;
prosody.core_post_stanza = core_post_stanza;
prosody.core_route_stanza = core_route_stanza;
