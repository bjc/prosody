
local connlisteners_register = require "net.connlisteners".register;
local connlisteners_get = require "net.connlisteners".get;

local httpserver_listener = connlisteners_get("httpserver");
local xmppserver_listener = connlisteners_get("xmppserver");
local xmppclient_listener = connlisteners_get("xmppclient");
local xmppcomponent_listener = connlisteners_get("xmppcomponent");

local server = { default_mode = "*a" };

local buffer = {};

function server.onincoming(conn, data)
	if not data then return; end
	local buf = buffer[conn];
	buffer[conn] = nil;
	buf = buf and buf..data or data;
	if buf:match("^[a-zA-Z]") then
		local listener = httpserver_listener;
		conn:setlistener(listener);
		local onconnect = listener.onconnect;
		if onconnect then onconnect(conn) end
		listener.onincoming(conn, buf);
	elseif buf:match(">") then
		local listener;
		local xmlns = buf:match("%sxmlns%s*=%s*['\"]([^'\"]*)");
		if xmlns == "jabber:server" then
			listener = xmppserver_listener;
		elseif xmlns == "jabber:component:accept" then
			listener = xmppcomponent_listener;
		else
			listener = xmppclient_listener;
		end
		conn:setlistener(listener);
		local onconnect = listener.onconnect;
		if onconnect then onconnect(conn) end
		listener.onincoming(conn, buf);
	elseif #buf > 1024 then
		conn:close();
	else
		buffer[conn] = buf;
	end
end

function server.ondisconnect(conn, err)
	buffer[conn] = nil; -- warn if no buffer?
end

connlisteners_register("multiplex", server);
