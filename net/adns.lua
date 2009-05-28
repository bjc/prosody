local server = require "net.server";
local dns = require "net.dns";

local log = require "util.logger".init("adns");

local coroutine, tostring, pcall = coroutine, tostring, pcall;

module "adns"

function lookup(handler, qname, qtype, qclass)
	return coroutine.wrap(function (peek)
				if peek then
					log("debug", "Records for %s already cached, using those...", qname);
					handler(peek);
					return;
				end
				log("debug", "Records for %s not in cache, sending query (%s)...", qname, tostring(coroutine.running()));
				dns.query(qname, qtype, qclass);
				coroutine.yield({ qclass or "IN", qtype or "A", qname, coroutine.running()}); -- Wait for reply
				log("debug", "Reply for %s (%s)", qname, tostring(coroutine.running()));
				local ok, err = pcall(handler, dns.peek(qname, qtype, qclass));
				if not ok then
					log("debug", "Error in DNS response handler: %s", tostring(err));
				end
			end)(dns.peek(qname, qtype, qclass));
end

function cancel(handle, call_handler)
	log("warn", "Cancelling DNS lookup for %s", tostring(handle[3]));
	dns.cancel(handle);
	if call_handler then
		coroutine.resume(handle[4]);
	end
end

function new_async_socket(sock)
	local newconn = {};
	local listener = {};
	function listener.incoming(conn, data)
		dns.feed(sock, data);
	end
	function listener.disconnect()
	end
	newconn.handler, newconn._socket = server.wrapclient(sock, "dns", 53, listener);
	newconn.handler.settimeout = function () end
	newconn.handler.setsockname = function (_, ...) return sock:setsockname(...); end
	newconn.handler.setpeername = function (_, ...) local ret = sock:setpeername(...); _.setsend(sock.send); return ret; end
	newconn.handler.connect = function (_, ...) return sock:connect(...) end	
	newconn.handler.send = function (_, data) _.write(data); return _.sendbuffer(); end	
	return newconn.handler;
end

dns:socket_wrapper_set(new_async_socket);

return _M;
