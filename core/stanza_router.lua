
-- The code in this file should be self-explanatory, though the logic is horrible
-- for more info on that, see doc/stanza_routing.txt, which attempts to condense
-- the rules from the RFCs (mainly 3921)

require "core.servermanager"

local log = require "util.logger".init("stanzarouter")

local st = require "util.stanza";
local send = require "core.sessionmanager".send_to_session;
local send_s2s = require "core.s2smanager".send_to_host;
local user_exists = require "core.usermanager".user_exists;

local s2s_verify_dialback = require "core.s2smanager".verify_dialback;
local s2s_make_authenticated = require "core.s2smanager".make_authenticated;
local format = string.format;
local tostring = tostring;

local jid_split = require "util.jid".split;
local print = print;

function core_process_stanza(origin, stanza)
	log("debug", "Received: "..tostring(stanza))
	-- TODO verify validity of stanza (as well as JID validity)
	if stanza.name == "iq" and not(#stanza.tags == 1 and stanza.tags[1].attr.xmlns) then
		if stanza.attr.type == "set" or stanza.attr.type == "get" then
			error("Invalid IQ");
		elseif #stanza.tags > 1 or not(stanza.attr.type == "error" or stanza.attr.type == "result") then
			error("Invalid IQ");
		end
	end

	if origin.type == "c2s" and not origin.full_jid
		and not(stanza.name == "iq" and stanza.tags[1].name == "bind"
				and stanza.tags[1].attr.xmlns == "urn:ietf:params:xml:ns:xmpp-bind") then
		error("Client MUST bind resource after auth");
	end

	local to = stanza.attr.to;
	-- TODO also, stazas should be returned to their original state before the function ends
	if origin.type == "c2s" then
		stanza.attr.from = origin.full_jid; -- quick fix to prevent impersonation (FIXME this would be incorrect when the origin is not c2s)
	end
	
	if not to then
			core_handle_stanza(origin, stanza);
	elseif hosts[to] and hosts[to].type == "local" then
		core_handle_stanza(origin, stanza);
	elseif stanza.name == "iq" and not select(3, jid_split(to)) then
		core_handle_stanza(origin, stanza);
	elseif origin.type == "c2s" then
		core_route_stanza(origin, stanza);
	end
end

-- This function handles stanzas which are not routed any further,
-- that is, they are handled by this server
function core_handle_stanza(origin, stanza)
	-- Handlers
	if origin.type == "c2s" or origin.type == "c2s_unauthed" then
		local session = origin;
		
		if stanza.name == "presence" and origin.roster then
			if stanza.attr.type == nil or stanza.attr.type == "available" or stanza.attr.type == "unavailable" then
				for jid in pairs(origin.roster) do -- broadcast to all interested contacts
					local subscription = origin.roster[jid].subscription;
					if subscription == "both" or subscription == "from" then
						stanza.attr.to = jid;
						core_route_stanza(origin, stanza);
					end
				end
				--[[local node, host = jid_split(stanza.attr.from);
				for _, res in pairs(hosts[host].sessions[node].sessions) do -- broadcast to all resources
					if res.full_jid then
						res = user.sessions[k];
						break;
					end
				end]]
				if not origin.presence then -- presence probes on initial presence
					local probe = st.presence({from = origin.full_jid, type = "probe"});
					for jid in pairs(origin.roster) do
						local subscription = origin.roster[jid].subscription;
						if subscription == "both" or subscription == "to" then
							probe.attr.to = jid;
							core_route_stanza(origin, probe);
						end
					end
				end
				origin.presence = stanza;
				stanza.attr.to = nil; -- reset it
			else
				-- TODO error, bad type
			end
		else
			log("debug", "Routing stanza to local");
			handle_stanza(session, stanza);
		end
	elseif origin.type == "s2sin_unauthed" then
		if stanza.name == "verify" and stanza.attr.xmlns == "jabber:server:dialback" then
			log("debug", "verifying dialback key...");
			local attr = stanza.attr;
			print(tostring(attr.to), tostring(attr.from))
			print(tostring(origin.to_host), tostring(origin.from_host))
			-- FIXME: Grr, ejabberd breaks this one too?? it is black and white in XEP-220 example 34
			--if attr.from ~= origin.to_host then error("invalid-from"); end
			local type = "invalid";
			if s2s_verify_dialback(attr.id, attr.from, attr.to, stanza[1]) then
				type = "valid"
			end
			origin.send(format("<db:verify from='%s' to='%s' id='%s' type='%s'>%s</db:verify>", attr.to, attr.from, attr.id, type, stanza[1]));
		end
	elseif origin.type == "s2sout_unauthed" then
		if stanza.name == "result" and stanza.attr.xmlns == "jabber:server:dialback" then
			if stanza.attr.type == "valid" then
				s2s_make_authenticated(origin);
			else
				-- FIXME
				error("dialback failed!");
			end
		end
	else
		log("warn", "Unhandled origin: %s", origin.type);
	end
end

-- TODO: Does this function belong here?
function is_authorized_to_see_presence(origin, username, host)
	local roster = datamanager.load(username, host, "roster") or {};
	local item = roster[origin.username.."@"..origin.host];
	return item and (item.subscription == "both" or item.subscription == "from");
end

function core_route_stanza(origin, stanza)
	-- Hooks
	--- ...later
	
	-- Deliver
	local to = stanza.attr.to;
	local node, host, resource = jid_split(to);

	if stanza.name == "presence" and stanza.attr.type == "probe" then resource = nil; end

	local host_session = hosts[host]
	if host_session and host_session.type == "local" then
		-- Local host
		local user = host_session.sessions[node];
		if user then
			local res = user.sessions[resource];
			if not res then
				-- if we get here, resource was not specified or was unavailable
				if stanza.name == "presence" then
					if stanza.attr.type == "probe" then
						if is_authorized_to_see_presence(origin, node, host) then
							for k in pairs(user.sessions) do -- return presence for all resources
								if user.sessions[k].presence then
									local pres = user.sessions[k].presence;
									pres.attr.to = origin.full_jid;
									pres.attr.from = user.sessions[k].full_jid;
									send(origin, pres);
									pres.attr.to = nil;
									pres.attr.from = nil;
								end
							end
						else
							send(origin, st.presence({from = user.."@"..host, to = origin.username.."@"..origin.host, type = "unsubscribed"}));
						end
					else
						for k in pairs(user.sessions) do -- presence broadcast to all user resources
							if user.sessions[k].full_jid then
								stanza.attr.to = user.sessions[k].full_jid;
								send(user.sessions[k], stanza);
							end
						end
					end
				elseif stanza.name == "message" then -- select a resource to recieve message
					for k in pairs(user.sessions) do
						if user.sessions[k].full_jid then
							res = user.sessions[k];
							break;
						end
					end
					-- TODO find resource with greatest priority
					send(res, stanza);
				else
					-- TODO send IQ error
				end
			else
				-- User + resource is online...
				stanza.attr.to = res.full_jid;
				send(res, stanza); -- Yay \o/
			end
		else
			-- user not online
			if user_exists(node, host) then
				if stanza.name == "presence" then
					if stanza.attr.type == "probe" and is_authorized_to_see_presence(origin, node, host) then -- FIXME what to do for not c2s?
						-- TODO send last recieved unavailable presence
					else
						-- TODO send unavailable presence
					end
				elseif stanza.name == "message" then
					-- TODO send message error, or store offline messages
				elseif stanza.name == "iq" then
					-- TODO send IQ error
				end
			else -- user does not exist
				-- TODO we would get here for nodeless JIDs too. Do something fun maybe? Echo service? Let plugins use xmpp:server/resource addresses?
				if stanza.name == "presence" then
					if stanza.attr.type == "probe" then
						send(origin, st.presence({from = user.."@"..host, to = origin.username.."@"..origin.host, type = "unsubscribed"}));
					end
					-- else ignore
				else
					send(origin, st.error_reply(stanza, "cancel", "service-unavailable"));
				end
			end
		end
	else
		-- Remote host
		log("debug", "sending s2s stanza: %s", tostring(stanza));
		stanza.attr.xmlns = "jabber:server";
		send_s2s(origin.host, host, stanza);
	end
	stanza.attr.to = to; -- reset
end

function handle_stanza_toremote(stanza)
	log("error", "Stanza bound for remote host, but s2s is not implemented");
end
