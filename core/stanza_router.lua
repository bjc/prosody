
-- The code in this file should be self-explanatory, though the logic is horrible
-- for more info on that, see doc/stanza_routing.txt, which attempts to condense
-- the rules from the RFCs (mainly 3921)

require "core.servermanager"

local log = require "util.logger".init("stanzarouter")

local st = require "util.stanza";
local send = require "core.sessionmanager".send_to_session;

local jid_split = require "util.jid".split;

function core_process_stanza(origin, stanza)
	log("debug", "Received: "..tostring(stanza))
	-- TODO verify validity of stanza (as well as JID validity)
	if stanza.name == "iq" and not(#stanza.tags == 1 and stanza.tags[1].attr.xmlns) then
		error("Invalid IQ");
	end

	if origin.type == "c2s" and not origin.full_jid
		and not(stanza.name == "iq" and stanza.tags[1].name == "bind"
				and stanza.tags[1].attr.xmlns == "urn:ietf:params:xml:ns:xmpp-bind") then
		error("Client MUST bind resource after auth");
	end

	
	local to = stanza.attr.to;
	stanza.attr.from = origin.full_jid -- quick fix to prevent impersonation
	
	if not to or (hosts[to] and hosts[to].type == "local") then
		core_handle_stanza(origin, stanza);
	elseif to and stanza.name == "iq" and not select(3, jid_split(to)) then
		core_handle_stanza(origin, stanza);
	elseif origin.type == "c2s" then
		core_route_stanza(origin, stanza);
	end
end

function core_handle_stanza(origin, stanza)
	-- Handlers
	if origin.type == "c2s" or origin.type == "c2s_unauthed" then
		local session = origin;
		stanza.attr.from = session.full_jid;
		
		log("debug", "Routing stanza");
		-- Stanza has no to attribute
		--local to_node, to_host, to_resource = jid_split(stanza.attr.to);
		--if not to_host then error("Invalid destination JID: "..string.format("{ %q, %q, %q } == %q", to_node or "", to_host or "", to_resource or "", stanza.attr.to or "nil")); end
		
		-- Stanza is to this server, or a user on this server
		log("debug", "Routing stanza to local");
		handle_stanza(session, stanza);
	end
end

function core_route_stanza(origin, stanza)
	-- Hooks
	--- ...later
	
	-- Deliver
	local node, host, resource = jid_split(stanza.attr.to);
	local host_session = hosts[host]
	if host_session and host_session.type == "local" then
		-- Local host
		local user = host_session.sessions[node];
		if user then
			local res = user.sessions[resource];
			if not res then
				-- if we get here, resource was not specified or was unavailable
				if stanza.name == "presence" then
					for k in pairs(user.sessions) do -- presence broadcast to all user resources
						if user.sessions[k].full_jid then
							stanza.attr.to = user.sessions[k].full_jid;
							send(user.sessions[k], stanza);
						end
					end
				else if stanza.name == "message" then -- select a resource to recieve message
					for k in pairs(user.sessions) do
						if user.sessions[k].full_jid then
							res = user.sessions[k];
							break;
						end
					end
					-- TODO find resource with greatest priority
				else
					error("IQs should't get here");
				end
			end
			if res then
				stanza.attr.to = res.full_jid;
				send(res, stanza); -- Yay \o/
			elseif stanza.name == "message" then
				-- TODO return message error
			end
		else
			-- user not found
			send(origin, st.error_reply(stanza, "cancel", "service-unavailable"));
		end
	else
		-- Remote host
		if host_session then
			-- Send to session
		else
			-- Need to establish the connection
		end
	end
end

function handle_stanza_nodest(stanza)
	if stanza.name == "iq" then
		handle_stanza_iq_no_to(session, stanza);
	elseif stanza.name == "presence" then
		-- Broadcast to this user's contacts
		handle_stanza_presence_broadcast(session, stanza);
		-- also, if it is initial presence, send out presence probes
		if not session.last_presence then
			handle_stanza_presence_probe_broadcast(session, stanza);
		end
		session.last_presence = stanza;
	elseif stanza.name == "message" then
		-- Treat as if message was sent to bare JID of the sender
		handle_stanza_to_local_user(stanza);
	end
end

function handle_stanza_tolocal(stanza)
	local node, host, resource = jid.split(stanza.attr.to);
	if host and hosts[host] and hosts[host].type == "local" then
			-- Is a local host, handle internally
			if node then
				-- Is a local user, send to their session
				log("debug", "Routing stanza to %s@%s", node, host);
				if not session.username then return; end --FIXME: Correct response when trying to use unauthed stream is what?
				handle_stanza_to_local_user(stanza);
			else
				-- Is sent to this server, let's handle it...
				log("debug", "Routing stanza to %s", host);
				handle_stanza_to_server(stanza, session);
			end
	end
end

function handle_stanza_toremote(stanza)
	log("error", "Stanza bound for remote host, but s2s is not implemented");
end


--[[
local function route_c2s_stanza(session, stanza)
	stanza.attr.from = session.full_jid;
	if not stanza.attr.to and session.username then
		-- Has no 'to' attribute, handle internally
		if stanza.name == "iq" then
			handle_stanza_iq_no_to(session, stanza);
		elseif stanza.name == "presence" then
			-- Broadcast to this user's contacts
			handle_stanza_presence_broadcast(session, stanza);
			-- also, if it is initial presence, send out presence probes
			if not session.last_presence then
				handle_stanza_presence_probe_broadcast(session, stanza);
			end
			session.last_presence = stanza;
		elseif stanza.name == "message" then
			-- Treat as if message was sent to bare JID of the sender
			handle_stanza_to_local_user(stanza);
		end
	end
	local node, host, resource = jid.split(stanza.attr.to);
	if host and hosts[host] and hosts[host].type == "local" then
			-- Is a local host, handle internally
			if node then
				-- Is a local user, send to their session
				if not session.username then return; end --FIXME: Correct response when trying to use unauthed stream is what?
				handle_stanza_to_local_user(stanza);
			else
				-- Is sent to this server, let's handle it...
				handle_stanza_to_server(stanza, session);
			end
	else
		-- Is not for us or a local user, route accordingly
		route_s2s_stanza(stanza);
	end
end

function handle_stanza_no_to(session, stanza)
	if not stanza.attr.id then log("warn", "<iq> without id attribute is invalid"); end
	local xmlns = (stanza.tags[1].attr and stanza.tags[1].attr.xmlns);
	if stanza.attr.type == "get" or stanza.attr.type == "set" then
		if iq_handlers[xmlns] then
			if iq_handlers[xmlns](stanza) then return; end; -- If handler returns true, it handled it
		end
		-- Oh, handler didn't handle it. Need to send service-unavailable now.
		log("warn", "Unhandled namespace: "..xmlns);
		session:send(format("<iq type='error' id='%s'><error type='cancel'><service-unavailable/></error></iq>", stanza.attr.id));
		return; -- All done!
	end
end

function handle_stanza_to_local_user(stanza)
	if stanza.name == "message" then
		handle_stanza_message_to_local_user(stanza);
	elseif stanza.name == "presence" then
		handle_stanza_presence_to_local_user(stanza);
	elseif stanza.name == "iq" then
		handle_stanza_iq_to_local_user(stanza);
	end
end

function handle_stanza_message_to_local_user(stanza)
	local node, host, resource = stanza.to.node, stanza.to.host, stanza.to.resource;
	local destuser = hosts[host].sessions[node];
	if destuser then
		if resource and destuser[resource] then
			destuser[resource]:send(stanza);
		else
			-- Bare JID, or resource offline
			local best_session;
			for resource, session in pairs(destuser.sessions) do
				if not best_session then best_session = session;
				elseif session.priority >= best_session.priority and session.priority >= 0 then
					best_session = session;
				end
			end
			if not best_session then
				offlinemessage.new(node, host, stanza);
			else
				print("resource '"..resource.."' was not online, have chosen to send to '"..best_session.username.."@"..best_session.host.."/"..best_session.resource.."'");
				destuser[best_session]:send(stanza);
			end
		end
	else
		-- User is offline
		offlinemessage.new(node, host, stanza);
	end
end

function handle_stanza_presence_to_local_user(stanza)
	local node, host, resource = stanza.to.node, stanza.to.host, stanza.to.resource;
	local destuser = hosts[host].sessions[node];
	if destuser then
		if resource then
			if destuser[resource] then
				destuser[resource]:send(stanza);
			else
				return;
			end
		else
			-- Broadcast to all user's resources
			for resource, session in pairs(destuser.sessions) do
				session:send(stanza);
			end
		end
	end
end

function handle_stanza_iq_to_local_user(stanza)

end

function foo()
		local node, host, resource = stanza.to.node, stanza.to.host, stanza.to.resource;
		local destuser = hosts[host].sessions[node];
		if destuser and destuser.sessions then
			-- User online
			if resource and destuser.sessions[resource] then
				stanza.to:send(stanza);
			else
				--User is online, but specified resource isn't (or no resource specified)
				local best_session;
				for resource, session in pairs(destuser.sessions) do
					if not best_session then best_session = session;
					elseif session.priority >= best_session.priority and session.priority >= 0 then
						best_session = session;
					end
				end
				if not best_session then
					offlinemessage.new(node, host, stanza);
				else
					print("resource '"..resource.."' was not online, have chosen to send to '"..best_session.username.."@"..best_session.host.."/"..best_session.resource.."'");
					resource = best_session.resource;
				end
			end
			if destuser.sessions[resource] == session then
				log("warn", "core", "Attempt to send stanza to self, dropping...");
			else
				print("...sending...", tostring(stanza));
				--destuser.sessions[resource].conn.write(tostring(data));
				print("   to conn ", destuser.sessions[resource].conn);
				destuser.sessions[resource].conn.write(tostring(stanza));
				print("...sent")
			end
		elseif stanza.name == "message" then
			print("   ...will be stored offline");
			offlinemessage.new(node, host, stanza);
		elseif stanza.name == "iq" then
			print("   ...is an iq");
			stanza.from:send(st.reply(stanza)
				:tag("error", { type = "cancel" })
					:tag("service-unavailable", { xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas" }));
		end
end

-- Broadcast a presence stanza to all of a user's contacts
function handle_stanza_presence_broadcast(session, stanza)
	if session.roster then
		local initial_presence = not session.last_presence;
		session.last_presence = stanza;
		
		-- Broadcast presence and probes
		local broadcast = st.presence({ from = session.full_jid, type = stanza.attr.type });

		for child in stanza:childtags() do
			broadcast:add_child(child);
		end
		for contact_jid in pairs(session.roster) do
			broadcast.attr.to = contact_jid;
			send_to(contact_jid, broadcast);
			if initial_presence then
				local node, host = jid.split(contact_jid);
				if hosts[host] and hosts[host].type == "local" then
					local contact = hosts[host].sessions[node]
					if contact then
						local pres = st.presence { to = session.full_jid };
						for resource, contact_session in pairs(contact.sessions) do
							if contact_session.last_presence then
								pres.tags = contact_session.last_presence.tags;
								pres.attr.from = contact_session.full_jid;
								send(pres);
							end
						end
					end
					--FIXME: Do we send unavailable if they are offline?
				else
					probe.attr.to = contact;
					send_to(contact, probe);
				end
			end
		end
		
		-- Probe for our contacts' presence
	end
end

-- Broadcast presence probes to all of a user's contacts
function handle_stanza_presence_probe_broadcast(session, stanza)
end

-- 
function handle_stanza_to_server(stanza)
end

function handle_stanza_iq_no_to(session, stanza)
end
]]