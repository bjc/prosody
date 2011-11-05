-- Prosody IM
-- Copyright (C) 2008-2011 Matthew Wild
-- Copyright (C) 2008-2011 Waqas Hussain
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
local jid_compare, jid_prep = require "util.jid".compare, require "util.jid".prep;
local st = require "util.stanza";
local connlisteners = require "net.connlisteners";
local sha1 = require "util.hashes".sha1;
local server = require "net.server";
local b64 = require "util.encodings".base64.encode;

local host, name = module:get_host(), "SOCKS5 Bytestreams Service";
local sessions, transfers = {}, {};

local proxy_port = module:get_option("proxy65_port") or 5000;
local proxy_interface = module:get_option("proxy65_interface") or "*";
local proxy_address = module:get_option("proxy65_address") or (proxy_interface ~= "*" and proxy_interface) or host;
local proxy_acl = module:get_option("proxy65_acl");
local max_buffer_size = 4096;

local connlistener = { default_port = proxy_port, default_interface = proxy_interface, default_mode = "*a" };

function connlistener.onincoming(conn, data)
	local session = sessions[conn] or {};

	local transfer = transfers[session.sha];
	if transfer and transfer.activated then -- copy data between initiator and target
		local initiator, target = transfer.initiator, transfer.target;
		(conn == initiator and target or initiator):write(data);
		return;
	end -- FIXME server.link should be doing this?
	
	if not session.greeting_done then
		local nmethods = data:byte(2) or 0;
		if data:byte(1) == 0x05 and nmethods > 0 and #data == 2 + nmethods then -- check if we have all the data
			if data:find("%z") then -- 0x00 = 'No authentication' is supported
				session.greeting_done = true;
				sessions[conn] = session;
				conn:write("\5\0"); -- send (SOCKS version 5, No authentication)
				module:log("debug", "SOCKS5 greeting complete");
				return;
			end
		end -- else error, unexpected input
		conn:write("\5\255"); -- send (SOCKS version 5, no acceptable method)
		conn:close();
		module:log("debug", "Invalid SOCKS5 greeting recieved: '%s'", b64(data));
	else -- connection request
		--local head = string.char( 0x05, 0x01, 0x00, 0x03, 40 ); -- ( VER=5=SOCKS5, CMD=1=CONNECT, RSV=0=RESERVED, ATYP=3=DOMAIMNAME, SHA-1 size )
		if #data == 47 and data:sub(1,5) == "\5\1\0\3\40" and data:sub(-2) == "\0\0" then
			local sha = data:sub(6, 45);
			conn:pause();
			conn:write("\5\0\0\3\40" .. sha .. "\0\0"); -- VER, REP, RSV, ATYP, BND.ADDR (sha), BND.PORT (2 Byte)
			if not transfers[sha] then
				transfers[sha] = {};
				transfers[sha].target = conn;
				session.sha = sha;
				module:log("debug", "SOCKS5 target connected for session %s", sha);
			else -- transfers[sha].target ~= nil
				transfers[sha].initiator = conn;
				session.sha = sha;
				module:log("debug", "SOCKS5 initiator connected for session %s", sha);
				server.link(conn, transfers[sha].target, max_buffer_size);
				server.link(transfers[sha].target, conn, max_buffer_size);
			end
		else -- error, unexpected input
			conn:write("\5\1\0\3\0\0\0"); -- VER, REP, RSV, ATYP, BND.ADDR (sha), BND.PORT (2 Byte)
			conn:close();
			module:log("debug", "Invalid SOCKS5 negotiation recieved: '%s'", b64(data));
		end
	end
end

function connlistener.ondisconnect(conn, err)
	local session = sessions[conn];
	if session then
		if transfers[session.sha] then
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
	origin.send(st.reply(stanza):query("http://jabber.org/protocol/disco#info")
		:tag("identity", {category='proxy', type='bytestreams', name=name}):up()
		:tag("feature", {var="http://jabber.org/protocol/bytestreams"}) );
	return true;
end, -1);

module:hook("iq-get/host/http://jabber.org/protocol/disco#items:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	origin.send(st.reply(stanza):query("http://jabber.org/protocol/disco#items"));
	return true;
end, -1);

module:hook("iq-get/host/http://jabber.org/protocol/bytestreams:query", function(event)
	local origin, stanza = event.origin, event.stanza;
	
	-- check ACL
	while proxy_acl and #proxy_acl > 0 do -- using 'while' instead of 'if' so we can break out of it
		local jid = stanza.attr.from;
		for _, acl in ipairs(proxy_acl) do
			if jid_compare(jid, acl) then break; end
		end
		module:log("warn", "Denying use of proxy for %s", tostring(stanza.attr.from));
		origin.send(st.error_reply(stanza, "auth", "forbidden"));
		return true;
	end

	local sid = stanza.tags[1].attr.sid;
	origin.send(st.reply(stanza):tag("query", {xmlns="http://jabber.org/protocol/bytestreams", sid=sid})
		:tag("streamhost", {jid=host, host=proxy_address, port=proxy_port}));
	return true;
end);

module.unload = function()
	connlisteners.deregister(module.host .. ':proxy65');
end

module:hook("iq-set/host/http://jabber.org/protocol/bytestreams:query", function(event)
	local origin, stanza = event.origin, event.stanza;

	local query = stanza.tags[1];
	local sid = query.attr.sid;
	local from = stanza.attr.from;
	local to = query:get_child_text("activate");
	local prepped_to = jid_prep(to);

	local info = "sid: "..tostring(sid)..", initiator: "..tostring(from)..", target: "..tostring(prepped_to or to);
	if prepped_to and sid then
		local sha = sha1(sid .. from .. prepped_to, true);
		if not transfers[sha] then
			module:log("debug", "Activation request has unknown session id; activation failed (%s)", info);
			origin.send(st.error_reply(stanza, "modify", "item-not-found"));
		elseif not transfers[sha].initiator then
			module:log("debug", "The sender was not connected to the proxy; activation failed (%s)", info);
			origin.send(st.error_reply(stanza, "cancel", "not-allowed", "The sender (you) is not connected to the proxy"));
		--elseif not transfers[sha].target then -- can't happen, as target is set when a transfer object is created
		--	module:log("debug", "The recipient was not connected to the proxy; activation failed (%s)", info);
		--	origin.send(st.error_reply(stanza, "cancel", "not-allowed", "The recipient is not connected to the proxy"));
		else -- if transfers[sha].initiator ~= nil and transfers[sha].target ~= nil then
			module:log("debug", "Transfer activated (%s)", info);
			transfers[sha].activated = true;
			transfers[sha].target:resume();
			transfers[sha].initiator:resume();
			origin.send(st.reply(stanza));
		end
	elseif to and sid then
		module:log("debug", "Malformed activation jid; activation failed (%s)", info);
		origin.send(st.error_reply(stanza, "modify", "jid-malformed"));
	else
		module:log("debug", "Bad request; activation failed (%s)", info);
		origin.send(st.error_reply(stanza, "modify", "bad-request"));
	end
	return true;
end);

if not connlisteners.register(module.host .. ':proxy65', connlistener) then
	module:log("error", "mod_proxy65: Could not establish a connection listener. Check your configuration please.");
	module:log("error", "Possibly two proxy65 components are configured to share the same port.");
end

connlisteners.start(module.host .. ':proxy65');
