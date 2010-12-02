-- Copyright (C) 2009 Thilo Cestonaro
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
--[[
* to restart the proxy in the console: e.g.
module:unload("proxy65");
> server.removeserver(<proxy65_port>);
module:load("proxy65", <proxy65_jid>);
]]--


local module = module;
local tostring = tostring;
local jid_split, jid_join, jid_compare = require "util.jid".split, require "util.jid".join, require "util.jid".compare;
local st = require "util.stanza";
local connlisteners = require "net.connlisteners";
local sha1 = require "util.hashes".sha1;
local server = require "net.server";

local host, name = module:get_host(), "SOCKS5 Bytestreams Service";
local sessions, transfers, replies_cache = {}, {}, {};

local proxy_port = module:get_option("proxy65_port") or 5000;
local proxy_interface = module:get_option("proxy65_interface") or "*";
local proxy_address = module:get_option("proxy65_address") or (proxy_interface ~= "*" and proxy_interface) or host;
local proxy_acl = module:get_option("proxy65_acl");
local max_buffer_size = 4096;

local connlistener = { default_port = proxy_port, default_interface = proxy_interface, default_mode = "*a" };

function connlistener.onincoming(conn, data)
	local session = sessions[conn] or {};
	
	if session.setup == nil and data ~= nil and data:byte(1) == 0x05 and #data > 2 then
		local nmethods = data:byte(2);
		local methods = data:sub(3);
		local supported = false;
		for i=1, nmethods, 1 do
			if(methods:byte(i) == 0x00) then -- 0x00 == method: NO AUTH
				supported = true;
				break;
			end
		end
		if(supported) then
			module:log("debug", "new session found ... ")
			session.setup = true;
			sessions[conn] = session;
			conn:write(string.char(5, 0));
		end
		return;
	end
	if session.setup then
		if session.sha ~= nil and transfers[session.sha] ~= nil then
			local sha = session.sha;
			if transfers[sha].activated == true and transfers[sha].target ~= nil then
				if  transfers[sha].initiator == conn then
					transfers[sha].target:write(data);
				else
					transfers[sha].initiator:write(data);
				end
				return;
			end
		end
		if data ~= nil and #data == 0x2F and  -- 40 == length of SHA1 HASH, and 7 other bytes => 47 => 0x2F
			data:byte(1) == 0x05 and -- SOCKS5 has 5 in first byte
			data:byte(2) == 0x01 and -- CMD must be 1
			data:byte(3) == 0x00 and -- RSV must be 0
			data:byte(4) == 0x03 and -- ATYP must be 3
			data:byte(5) == 40 and -- SHA1 HASH length must be 40 (0x28)
			data:byte(-2) == 0x00 and -- PORT must be 0, size 2 byte
			data:byte(-1) == 0x00
		then
			local sha = data:sub(6, 45); -- second param is not count! it's the ending index (included!)
			if transfers[sha] == nil then
				transfers[sha] = {};
				transfers[sha].activated = false;
				transfers[sha].target = conn;
				session.sha = sha;
				module:log("debug", "target connected ... ");
			elseif transfers[sha].target ~= nil then
				transfers[sha].initiator = conn;
				session.sha = sha;
				module:log("debug", "initiator connected ... ");
				server.link(conn, transfers[sha].target, max_buffer_size);
				server.link(transfers[sha].target, conn, max_buffer_size);
			end
			conn:write(string.char(5, 0, 0, 3, #sha) .. sha .. string.char(0, 0)); -- VER, REP, RSV, ATYP, BND.ADDR (sha), BND.PORT (2 Byte)
			conn:lock_read(true)
		else
			module:log("warn", "Neither data transfer nor initial connect of a participator of a transfer.")
			conn:close();
		end
	else
		if data ~= nil then
			module:log("warn", "unknown connection with no authentication data -> closing it");
			conn:close();
		end
	end
end

function connlistener.ondisconnect(conn, err)
	local session = sessions[conn];
	if session then
		if session.sha and transfers[session.sha] then
			local initiator, target = transfers[session.sha].initiator, transfers[session.sha].target;
			if initiator == conn and target ~= nil then
				target:close();
			elseif target == conn and initiator ~= nil then
			 	initiator:close();
			end
			transfers[session.sha] = nil;
		end
		-- Clean up any session-related stuff here
		sessions[conn] = nil;
	end
end

module:add_identity("proxy", "bytestreams", name);
module:add_feature("http://jabber.org/protocol/bytestreams");

module:hook("iq-get/host/http://jabber.org/protocol/disco#info:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	local reply = replies_cache.disco_info;
	if reply == nil then
	 	reply = st.iq({type='result', from=host}):query("http://jabber.org/protocol/disco#info")
			:tag("identity", {category='proxy', type='bytestreams', name=name}):up()
			:tag("feature", {var="http://jabber.org/protocol/bytestreams"});
		replies_cache.disco_info = reply;
	end

	reply.attr.id = stanza.attr.id;
	reply.attr.to = stanza.attr.from;
	origin.send(reply);
	return true;
end, -1);

module:hook("iq-get/host/http://jabber.org/protocol/disco#items:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	local reply = replies_cache.disco_items;
	if reply == nil then
	 	reply = st.iq({type='result', from=host}):query("http://jabber.org/protocol/disco#items");
		replies_cache.disco_items = reply;
	end
	
	reply.attr.id = stanza.attr.id;
	reply.attr.to = stanza.attr.from;
	origin.send(reply);
	return true;
end, -1);

module:hook("iq-get/host/http://jabber.org/protocol/bytestreams:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	local reply = replies_cache.stream_host;
	local err_reply = replies_cache.stream_host_err;
	local sid = stanza.tags[1].attr.sid;
	local allow = false;
	local jid = stanza.attr.from;
	
	if proxy_acl and #proxy_acl > 0 then
		for _, acl in ipairs(proxy_acl) do
			if jid_compare(jid, acl) then allow = true; end
		end
	else
		allow = true;
	end
	if allow == true then
		if reply == nil then
			reply = st.iq({type="result", from=host})
				:query("http://jabber.org/protocol/bytestreams")
				:tag("streamhost", {jid=host, host=proxy_address, port=proxy_port});
			replies_cache.stream_host = reply;
		end
	else
		module:log("warn", "Denying use of proxy for %s", tostring(jid));
		if err_reply == nil then
			err_reply = st.iq({type="error", from=host})
				:query("http://jabber.org/protocol/bytestreams")
				:tag("error", {code='403', type='auth'})
				:tag("forbidden", {xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'});
			replies_cache.stream_host_err = err_reply;
		end
		reply = err_reply;
	end
	reply.attr.id = stanza.attr.id;
	reply.attr.to = stanza.attr.from;
	reply.tags[1].attr.sid = sid;
	origin.send(reply);
	return true;
end);

module.unload = function()
	connlisteners.deregister(module.host .. ':proxy65');
end

local function set_activation(stanza)
	local to, reply;
	local from = stanza.attr.from;
	local query = stanza.tags[1];
	local sid = query.attr.sid;
	if query.tags[1] and query.tags[1].name == "activate" then
		to = query.tags[1][1];
	end
	if from ~= nil and to ~= nil and sid ~= nil then
		reply = st.iq({type="result", from=host, to=from});
		reply.attr.id = stanza.attr.id;
	end
	return reply, from, to, sid;
end

module:hook("iq-set/host/http://jabber.org/protocol/bytestreams:query", function(event)
	local origin, stanza = event.origin, event.stanza;

	module:log("debug", "Received activation request from %s", stanza.attr.from);
	local reply, from, to, sid = set_activation(stanza);
	if reply ~= nil and from ~= nil and to ~= nil and sid ~= nil then
		local sha = sha1(sid .. from .. to, true);
		if transfers[sha] == nil then
			module:log("error", "transfers[sha]: nil");
		elseif(transfers[sha] ~= nil and transfers[sha].initiator ~= nil and transfers[sha].target ~= nil) then
			origin.send(reply);
			transfers[sha].activated = true;
			transfers[sha].target:lock_read(false);
			transfers[sha].initiator:lock_read(false);
		else
			module:log("debug", "Both parties were not yet connected");
			local message = "Neither party is connected to the proxy";
			if transfers[sha].initiator then
				message = "The recipient is not connected to the proxy";
			elseif transfers[sha].target then
				message = "The sender (you) is not connected to the proxy";
			end
			origin.send(st.error_reply(stanza, "cancel", "not-allowed", message));
		end
		return true;
	else
		module:log("error", "activation failed: sid: %s, initiator: %s, target: %s", tostring(sid), tostring(from), tostring(to));
	end
end);

if not connlisteners.register(module.host .. ':proxy65', connlistener) then
	module:log("error", "mod_proxy65: Could not establish a connection listener. Check your configuration please.");
	module:log("error", "Possibly two proxy65 components are configured to share the same port.");
end

connlisteners.start(module.host .. ':proxy65');
