--[[


			server.lua based on lua/libevent by blastbeat

			notes:
			-- when using luaevent, never register 2 or more EV_READ at one socket, same for EV_WRITE
			-- you can't even register a new EV_READ/EV_WRITE callback inside another one
			-- to do some of the above, use timeout events or something what will called from outside
			-- don't let garbagecollect eventcallbacks, as long they are running
			-- when using luasec, there are 4 cases of timeout errors: wantread or wantwrite during reading or writing

--]]
-- luacheck: ignore 212/self 431/err 211/ret

local SCRIPT_NAME           = "server_event.lua"
local SCRIPT_VERSION        = "0.05"
local SCRIPT_AUTHOR         = "blastbeat"
local LAST_MODIFIED         = "2009/11/20"

local cfg = {
	MAX_CONNECTIONS       = 100000,  -- max per server connections (use "ulimit -n" on *nix)
	MAX_HANDSHAKE_ATTEMPTS= 1000,  -- attempts to finish ssl handshake
	HANDSHAKE_TIMEOUT     = 60,  -- timeout in seconds per handshake attempt
	MAX_READ_LENGTH       = 1024 * 1024 * 1024 * 1024,  -- max bytes allowed to read from sockets
	MAX_SEND_LENGTH       = 1024 * 1024 * 1024 * 1024,  -- max bytes size of write buffer (for writing on sockets)
	ACCEPT_QUEUE          = 128,  -- might influence the length of the pending sockets queue
	ACCEPT_DELAY          = 10,  -- seconds to wait until the next attempt of a full server to accept
	READ_TIMEOUT          = 14 * 60,  -- timeout in seconds for read data from socket
	WRITE_TIMEOUT         = 180,  -- timeout in seconds for write data on socket
	CONNECT_TIMEOUT       = 20,  -- timeout in seconds for connection attempts
	CLEAR_DELAY           = 5,  -- seconds to wait for clearing interface list (and calling ondisconnect listeners)
	READ_RETRY_DELAY      = 1e-06, -- if, after reading, there is still data in buffer, wait this long and continue reading
	DEBUG                 = true,  -- show debug messages
}

local pairs = pairs
local select = select
local require = require
local tostring = tostring
local setmetatable = setmetatable

local t_insert = table.insert
local t_concat = table.concat
local s_sub = string.sub

local coroutine_wrap = coroutine.wrap
local coroutine_yield = coroutine.yield

local has_luasec = pcall ( require , "ssl" )
local socket = require "socket"
local levent = require "luaevent.core"
local inet = require "prosody.util.net";
local inet_pton = inet.pton;
local sslconfig = require "prosody.util.sslconfig";
local tls_impl = require "prosody.net.tls_luasec";

local socket_gettime = socket.gettime

local log = require ("prosody.util.logger").init("socket")

local function debug(...)
	return log("debug", ("%s "):rep(select('#', ...)), ...)
end
-- local vdebug = debug;

local bitor = ( function( ) -- thx Rici Lake
	local hasbit = function( x, p )
		return x % ( p + p ) >= p
	end
	return function( x, y )
		local p = 1
		local z = 0
		local limit = x > y and x or y
		while p <= limit do
			if hasbit( x, p ) or hasbit( y, p ) then
				z = z + p
			end
			p = p + p
		end
		return z
	end
end )( )

local base = levent.new( )
local addevent = base.addevent
local EV_READ = levent.EV_READ
local EV_WRITE = levent.EV_WRITE
local EV_TIMEOUT = levent.EV_TIMEOUT
local EV_SIGNAL = levent.EV_SIGNAL

local EV_READWRITE = bitor( EV_READ, EV_WRITE )

local interfacelist = { }

-- Client interface methods
local interface_mt = {}; interface_mt.__index = interface_mt;

-- Private methods
function interface_mt:_close()
	return self:_destroy();
end

function interface_mt:_start_connection(plainssl) -- called from wrapclient
	local callback = function( event )
		if EV_TIMEOUT == event then  -- timeout during connection
			self.fatalerror = "connection timeout"
			self:ontimeout()  -- call timeout listener
			self:_close()
			debug( "new connection failed. id:", self.id, "error:", self.fatalerror )
		else
			if EV_READWRITE == event then
				if self.readcallback(event) == -1 then
					-- Fatal error occurred
					return -1;
				end
			end
			if plainssl and has_luasec then  -- start ssl session
				self:starttls(self._sslctx, true)
			else  -- normal connection
				self:_start_session(true)
			end
			debug( "new connection established. id:", self.id )
		end
		self.eventconnect = nil
		return -1
	end
	self.eventconnect = addevent( base, self.conn, EV_READWRITE, callback, cfg.CONNECT_TIMEOUT )
	return true
end
function interface_mt:_start_session(call_onconnect) -- new session, for example after startssl
	if self.type == "client" then
		local callback = function( )
			self:_lock( false,  false, false )
			--vdebug( "start listening on client socket with id:", self.id )
			self.eventread = addevent( base, self.conn, EV_READ, self.readcallback, cfg.READ_TIMEOUT );  -- register callback
			if call_onconnect then
				self:onconnect()
			end
			self.eventsession = nil
			return -1
		end
		self.eventsession = addevent( base, nil, EV_TIMEOUT, callback, 0 )
	else
		self:_lock( false )
		--vdebug( "start listening on server socket with id:", self.id )
		self.eventread = addevent( base, self.conn, EV_READ, self.readcallback )  -- register callback
	end
	return true
end
function interface_mt:_start_ssl(call_onconnect) -- old socket will be destroyed, therefore we have to close read/write events first
	--vdebug( "starting ssl session with client id:", self.id )
	local _
	_ = self.eventread and self.eventread:close( )  -- close events; this must be called outside of the event callbacks!
	_ = self.eventwrite and self.eventwrite:close( )
	self.eventread, self.eventwrite = nil, nil
	local err
	self.conn, err = self._sslctx:wrap(self.conn)
	if err then
		self.fatalerror = err
		self.conn = nil  -- cannot be used anymore
		if call_onconnect then
			self.ondisconnect = nil  -- don't call this when client isn't really connected
		end
		self:_close()
		debug( "fatal error while ssl wrapping:", err )
		return false
	end

	if self.conn.sni then
		if self.servername then
			self.conn:sni(self.servername);
		elseif next(self._sslctx._sni_contexts) ~= nil then
			self.conn:sni(self._sslctx._sni_contexts, true);
		end
	end

	self.conn:settimeout( 0 )  -- set non blocking
	local handshakecallback = coroutine_wrap(function( event )
		local _, err
		local attempt = 0
		local maxattempt = cfg.MAX_HANDSHAKE_ATTEMPTS
		while attempt < maxattempt do  -- no endless loop
			attempt = attempt + 1
			debug( "ssl handshake of client with id:"..tostring(self)..", attempt:"..attempt )
			if attempt > maxattempt then
				self.fatalerror = "max handshake attempts exceeded"
			elseif EV_TIMEOUT == event then
				self.fatalerror = "timeout during handshake"
			else
				_, err = self.conn:dohandshake( )
				if not err then
					self:_lock( false, false, false )  -- unlock the interface; sending, closing etc allowed
					self.send = self.conn.send  -- caching table lookups with new client object
					self.receive = self.conn.receive
					if not call_onconnect then  -- trigger listener
						self:onstatus("ssl-handshake-complete");
					end
					self:_start_session( call_onconnect )
					debug( "ssl handshake done" )
					self.eventhandshake = nil
					return -1
				end
				if err == "wantwrite" then
					event = EV_WRITE
				elseif err == "wantread" then
					event = EV_READ
				else
					debug( "ssl handshake error:", err )
					self.fatalerror = err
				end
			end
			if self.fatalerror then
				if call_onconnect then
					self.ondisconnect = nil  -- don't call this when client isn't really connected
				end
				self:_close()
				debug( "handshake failed because:", self.fatalerror )
				self.eventhandshake = nil
				return -1
			end
			event = coroutine_yield( event, cfg.HANDSHAKE_TIMEOUT )  -- yield this monster...
		end
	end
	)
	debug "starting handshake..."
	self:_lock( false, true, true )  -- unlock read/write events, but keep interface locked
	self.eventhandshake = addevent( base, self.conn, EV_READWRITE, handshakecallback, cfg.HANDSHAKE_TIMEOUT )
	return true
end
function interface_mt:_destroy()  -- close this interface + events and call last listener
	debug( "closing client with id:", self.id, self.fatalerror )
	self:_lock( true, true, true )  -- first of all, lock the interface to avoid further actions
	local _
	_ = self.eventread and self.eventread:close( )
	if self.type == "client" then
		_ = self.eventwrite and self.eventwrite:close( )
		_ = self.eventhandshake and self.eventhandshake:close( )
		_ = self.eventstarthandshake and self.eventstarthandshake:close( )
		_ = self.eventconnect and self.eventconnect:close( )
		_ = self.eventsession and self.eventsession:close( )
		_ = self.eventwritetimeout and self.eventwritetimeout:close( )
		_ = self.eventreadtimeout and self.eventreadtimeout:close( )
		-- call ondisconnect listener (won't be the case if handshake failed on connect)
		_ = self.ondisconnect and self:ondisconnect( self.fatalerror ~= "client to close" and self.fatalerror)
		_ = self.conn and self.conn:close( ) -- close connection
		_ = self._server and self._server:counter(-1);
		self.eventread, self.eventwrite = nil, nil
		self.eventstarthandshake, self.eventhandshake, self.eventclose = nil, nil, nil
		self.readcallback, self.writecallback = nil, nil
	else
		self.conn:close( )
		self.eventread, self.eventclose = nil, nil
		self.interface, self.readcallback = nil, nil
	end
	interfacelist[ self ] = nil
	return true
end

function interface_mt:_lock(nointerface, noreading, nowriting)  -- lock or unlock this interface or events
	self.nointerface, self.noreading, self.nowriting = nointerface, noreading, nowriting
	return nointerface, noreading, nowriting
end

--TODO: Deprecate
function interface_mt:lock_read(switch)
	log("warn", ":lock_read is deprecated, use :pause() and :resume()");
	if switch then
		return self:pause();
	else
		return self:resume();
	end
end

function interface_mt:pause()
	return self:_lock(self.nointerface, true, self.nowriting);
end

function interface_mt:sslctx()
	return self._sslctx
end

function interface_mt:ssl_info()
	local sock = self.conn;
	if not sock.info then return nil, "not-implemented"; end
	return sock:info();
end

function interface_mt:ssl_peercertificate()
	local sock = self.conn;
	if not sock.getpeercertificate then return nil, "not-implemented"; end
	return sock:getpeercertificate();
end

function interface_mt:ssl_peerverification()
	local sock = self.conn;
	if not sock.getpeerverification then return nil, { { "Chain verification not supported" } }; end
	return sock:getpeerverification();
end

function interface_mt:ssl_peerfinished()
	local sock = self.conn;
	if not sock.getpeerfinished then return nil, "not-implemented"; end
	return sock:getpeerfinished();
end

function interface_mt:resume()
	self:_lock(self.nointerface, false, self.nowriting);
	if self.readcallback and not self.eventread then
		self.eventread = addevent( base, self.conn, EV_READ, self.readcallback, cfg.READ_TIMEOUT );  -- register callback
		return true;
	end
end

function interface_mt:pause_writes()
	return self:_lock(self.nointerface, self.noreading, true);
end

function interface_mt:resume_writes()
	self:_lock(self.nointerface, self.noreading, false);
	if self.writecallback and not self.eventwrite then
		self.eventwrite = addevent( base, self.conn, EV_WRITE, self.writecallback, cfg.WRITE_TIMEOUT );  -- register callback
		return true;
	end
end


function interface_mt:counter(c)
	if c then
		self._connections = self._connections + c
	end
	return self._connections
end

-- Public methods
function interface_mt:write(data)
	if self.nointerface then return nil, "locked"; end
	--vdebug( "try to send data to client, id/data:", self.id, data )
	data = tostring( data )
	local len = #data
	local total = len + self.writebufferlen
	if total > cfg.MAX_SEND_LENGTH then  -- check buffer length
		local err = "send buffer exceeded"
		debug( "error:", err )  -- to much, check your app
		return nil, err
	end
	t_insert(self.writebuffer, data) -- new buffer
	self.writebufferlen = total
	if not self.eventwrite and not self.nowriting  then  -- register new write event
		--vdebug( "register new write event" )
		self.eventwrite = addevent( base, self.conn, EV_WRITE, self.writecallback, cfg.WRITE_TIMEOUT )
	end
	return true
end
function interface_mt:close()
	if self.nointerface then return nil, "locked"; end
	debug( "try to close client connection with id:", self.id )
	if self.type == "client" then
		self.fatalerror = "client to close"
		if self.eventwrite then -- wait for incomplete write request
			self:_lock( true, true, false )
			debug "closing delayed until writebuffer is empty"
			return nil, "writebuffer not empty, waiting"
		else -- close now
			self:_lock( true, true, true )
			self:_close()
			return true
		end
	else
		debug( "try to close server with id:", tostring(self.id))
		self.fatalerror = "server to close"
		self:_lock( true )
		self:_close( 0 )
		return true
	end
end

function interface_mt:socket()
	return self.conn
end

function interface_mt:server()
	return self._server or self;
end

function interface_mt:port()
	return self._port
end

function interface_mt:serverport()
	return self._serverport
end

function interface_mt:ip()
	return self._ip
end

function interface_mt:ssl()
	return self._usingssl
end
interface_mt.clientport = interface_mt.port -- COMPAT server_select

function interface_mt:type()
	return self._type or "client"
end

function interface_mt:connections()
	return self._connections
end

function interface_mt:address()
	return self.addr
end

function interface_mt:set_sslctx(sslctx)
	self._sslctx = sslctx;
	if sslctx then
		self.starttls = nil; -- use starttls() of interface_mt
	else
		self.starttls = false; -- prevent starttls()
	end
end

function interface_mt:set_mode(pattern)
	if pattern then
		self._pattern = pattern;
	end
	return self._pattern;
end

function interface_mt:set_send(new_send) -- luacheck: ignore 212
	-- No-op, we always use the underlying connection's send
end

function interface_mt:starttls(sslctx, call_onconnect)
	debug( "try to start ssl at client id:", self.id )
	local err
	self._sslctx = sslctx;
	if self._usingssl then  -- startssl was already called
		err = "ssl already active"
	end
	if err then
		debug( "error:", err )
		return nil, err
	end
	self._usingssl = true
	self.startsslcallback = function( )  -- we have to start the handshake outside of a read/write event
		self.startsslcallback = nil
		self:_start_ssl(call_onconnect);
		self.eventstarthandshake = nil
		return -1
	end
	if not self.eventwrite then
		self:_lock( true, true, true )  -- lock the interface, to not disturb the handshake
		self.eventstarthandshake = addevent( base, nil, EV_TIMEOUT, self.startsslcallback, 0 )  -- add event to start handshake
	else
		-- wait until writebuffer is empty
		self:_lock( true, true, false )
		debug "ssl session delayed until writebuffer is empty..."
	end
	self.starttls = false;
	return true
end

function interface_mt:setoption(option, value)
	if self.conn.setoption then
		return self.conn:setoption(option, value);
	end
	return false, "setoption not implemented";
end

function interface_mt:setlistener(listener, data)
	self:ondetach(); -- Notify listener that it is no longer responsible for this connection
	self.onconnect = listener.onconnect;
	self.ondisconnect = listener.ondisconnect;
	self.onincoming = listener.onincoming;
	self.ontimeout = listener.ontimeout;
	self.onreadtimeout = listener.onreadtimeout;
	self.onstatus = listener.onstatus;
	self.ondetach = listener.ondetach;
	self.onattach = listener.onattach;
	self.onpredrain = listener.onpredrain;
	self.ondrain = listener.ondrain;
	self:onattach(data);
end

-- Stub handlers
function interface_mt:onconnect()
end
function interface_mt:onincoming()
end
function interface_mt:ondisconnect()
end
function interface_mt:ontimeout()
end
function interface_mt:onreadtimeout()
end
function interface_mt:onpredrain()
end
function interface_mt:ondrain()
end
function interface_mt:ondetach()
end
function interface_mt:onattach()
end
function interface_mt:onstatus()
end

-- End of client interface methods

local function handleclient( client, ip, port, server, pattern, listener, sslctx, extra )  -- creates an client interface
	--vdebug("creating client interfacce...")
	local interface = {
		type = "client";
		conn = client;
		currenttime = socket_gettime( );  -- safe the origin
		writebuffer = {};  -- writebuffer
		writebufferlen = 0;  -- length of writebuffer
		send = client.send;  -- caching table lookups
		receive = client.receive;
		onconnect = listener.onconnect;  -- will be called when client disconnects
		ondisconnect = listener.ondisconnect;  -- will be called when client disconnects
		onincoming = listener.onincoming;  -- will be called when client sends data
		ontimeout = listener.ontimeout; -- called when fatal socket timeout occurs
		onreadtimeout = listener.onreadtimeout; -- called when socket inactivity timeout occurs
		onpredrain = listener.onpredrain; -- called before writes
		ondrain = listener.ondrain; -- called when writebuffer is empty
		ondetach = listener.ondetach; -- called when disassociating this listener from this connection
		onstatus = listener.onstatus; -- called for status changes (e.g. of SSL/TLS)
		eventread = false, eventwrite = false, eventclose = false,
		eventhandshake = false, eventstarthandshake = false;  -- event handler
		eventconnect = false, eventsession = false;  -- more event handler...
		eventwritetimeout = false;  -- even more event handler...
		eventreadtimeout = false;
		fatalerror = false;  -- error message
		writecallback = false;  -- will be called on write events
		readcallback = false;  -- will be called on read events
		nointerface = true;  -- lock/unlock parameter of this interface
		noreading = false, nowriting = false;  -- locks of the read/writecallback
		startsslcallback = false;  -- starting handshake callback
		position = false;  -- position of client in interfacelist

		-- Properties
		_ip = ip, _port = port, _server = server, _pattern = pattern,
		_serverport = (server and server:port() or nil),
		_sslctx = sslctx; -- parameters
		_usingssl = false;  -- client is using ssl;
		extra = extra;
		servername = extra and extra.servername;
	}
	if not has_luasec then interface.starttls = false; end
	interface.id = tostring(interface):match("%x+$");
	interface.writecallback = function( event )  -- called on write events
		--vdebug( "new client write event, id/ip/port:", interface, ip, port )
		if interface.nowriting or ( interface.fatalerror and ( "client to close" ~= interface.fatalerror ) ) then  -- leave this event
			--vdebug( "leaving this event because:", interface.nowriting or interface.fatalerror )
			interface.eventwrite = false
			return -1
		end
		if EV_TIMEOUT == event then  -- took too long to write some data to socket -> disconnect
			interface.fatalerror = "timeout during writing"
			debug( "writing failed:", interface.fatalerror )
			interface:_close()
			interface.eventwrite = false
			return -1
		else  -- can write :)
			if interface._usingssl then  -- handle luasec
				if interface.eventreadtimeout then  -- we have to read first
					local ret = interface.readcallback( )  -- call readcallback
					--vdebug( "tried to read in writecallback, result:", ret )
				end
				if interface.eventwritetimeout then  -- luasec only
					interface.eventwritetimeout:close( )  -- first we have to close timeout event which where registered after a wantread error
					interface.eventwritetimeout = false
				end
			end
			interface:onpredrain();
			interface.writebuffer = { t_concat(interface.writebuffer) }
			local succ, err, byte = interface.conn:send( interface.writebuffer[1], 1, interface.writebufferlen )
			--vdebug( "write data:", interface.writebuffer, "error:", err, "part:", byte )
			if succ then  -- writing successful
				interface.writebuffer[1] = nil
				interface.writebufferlen = 0
				interface:ondrain();
				if interface.fatalerror then
					debug "closing client after writing"
					interface:_close()  -- close interface if needed
				elseif interface.startsslcallback then  -- start ssl connection if needed
					debug "starting ssl handshake after writing"
					interface.eventstarthandshake = addevent( base, nil, EV_TIMEOUT, interface.startsslcallback, 0 )
				elseif interface.writebufferlen ~= 0 then
					-- data possibly written from ondrain
					return EV_WRITE, cfg.WRITE_TIMEOUT
				elseif interface.eventreadtimeout then
					return EV_WRITE, cfg.WRITE_TIMEOUT
				end
				interface.eventwrite = nil
				return -1
			elseif byte and (err == "timeout" or err == "wantwrite") then  -- want write again
				--vdebug( "writebuffer is not empty:", err )
				interface.writebuffer[1] = s_sub( interface.writebuffer[1], byte + 1, interface.writebufferlen )  -- new buffer
				interface.writebufferlen = interface.writebufferlen - byte
				if "wantread" == err then  -- happens only with luasec
					local callback = function( )
						interface:_close()
						interface.eventwritetimeout = nil
						return -1;
					end
					interface.eventwritetimeout = addevent( base, nil, EV_TIMEOUT, callback, cfg.WRITE_TIMEOUT )  -- reg a new timeout event
					debug( "wantread during write attempt, reg it in readcallback but don't know what really happens next..." )
					-- hopefully this works with luasec; its simply not possible to use 2 different write events on a socket in luaevent
					return -1
				end
				return EV_WRITE, cfg.WRITE_TIMEOUT
			else  -- connection was closed during writing or fatal error
				interface.fatalerror = err or "fatal error"
				debug( "connection failed in write event:", interface.fatalerror )
				interface:_close()
				interface.eventwrite = nil
				return -1
			end
		end
	end

	interface.readcallback = function( event )  -- called on read events
		--vdebug( "new client read event, id/ip/port:", tostring(interface.id), tostring(ip), tostring(port) )
		if interface.noreading or interface.fatalerror then  -- leave this event
			--vdebug( "leaving this event because:", tostring(interface.noreading or interface.fatalerror) )
			interface.eventread = nil
			return -1
		end
		if EV_TIMEOUT == event and not interface.conn:dirty() and interface:onreadtimeout() ~= true then
			interface.fatalerror = "timeout during receiving"
			debug( "connection failed:", interface.fatalerror )
			interface:_close()
			interface.eventread = nil
			return -1 -- took too long to get some data from client -> disconnect
		end
		if interface._usingssl then  -- handle luasec
			if interface.eventwritetimeout then  -- ok, in the past writecallback was registered
				local ret = interface.writecallback( )  -- call it
				--vdebug( "tried to write in readcallback, result:", tostring(ret) )
			end
			if interface.eventreadtimeout then
				interface.eventreadtimeout:close( )
				interface.eventreadtimeout = nil
			end
		end
		local buffer, err, part = interface.conn:receive( interface._pattern )  -- receive buffer with "pattern"
		--vdebug( "read data:", tostring(buffer), "error:", tostring(err), "part:", tostring(part) )
		buffer = buffer or part
		if buffer and #buffer > cfg.MAX_READ_LENGTH then  -- check buffer length
			interface.fatalerror = "receive buffer exceeded"
			debug( "fatal error:", interface.fatalerror )
			interface:_close()
			interface.eventread = nil
			return -1
		end
		if err and ( err ~= "timeout" and err ~= "wantread" ) then
			if "wantwrite" == err then -- need to read on write event
				if not interface.eventwrite then  -- register new write event if needed
					interface.eventwrite = addevent( base, interface.conn, EV_WRITE, interface.writecallback, cfg.WRITE_TIMEOUT )
				end
				interface.eventreadtimeout = addevent( base, nil, EV_TIMEOUT,
					function( ) interface:_close() end, cfg.READ_TIMEOUT)
				debug( "wantwrite during read attempt, reg it in writecallback but don't know what really happens next..." )
				-- to be honest i don't know what happens next, if it is allowed to first read, the write etc...
			else  -- connection was closed or fatal error
				interface.fatalerror = err
				debug( "connection failed in read event:", interface.fatalerror )
				interface:_close()
				interface.eventread = nil
				return -1
			end
		else
			interface.onincoming( interface, buffer, err )  -- send new data to listener
		end
		if interface.noreading then
			interface.eventread = nil;
			return -1;
		end
		if interface.conn:dirty() then -- still data left in buffer
			return EV_TIMEOUT, cfg.READ_RETRY_DELAY;
		end
		return EV_READ, cfg.READ_TIMEOUT
	end

	client:settimeout( 0 )  -- set non blocking
	setmetatable(interface, interface_mt)
	interfacelist[ interface ] = true  -- add to interfacelist
	return interface
end

local function handleserver( server, addr, port, pattern, listener, sslctx, startssl )  -- creates a server interface
	debug "creating server interface..."
	local interface = {
		_connections = 0;

		type = "server";
		conn = server;
		onconnect = listener.onconnect;  -- will be called when new client connected
		eventread = false;  -- read event handler
		eventclose = false; -- close event handler
		readcallback = false; -- read event callback
		fatalerror = false; -- error message
		nointerface = true;  -- lock/unlock parameter

		_ip = addr, _port = port, _pattern = pattern,
		_sslctx = sslctx;
		hosts = {};
	}
	interface.id = tostring(interface):match("%x+$");
	interface.readcallback = function( event )  -- server handler, called on incoming connections
		--vdebug( "server can accept, id/addr/port:", interface, addr, port )
		if interface.fatalerror then
			--vdebug( "leaving this event because:", self.fatalerror )
			interface.eventread = nil
			return -1
		end
		local delay = cfg.ACCEPT_DELAY
		if EV_TIMEOUT == event then
			if interface._connections >= cfg.MAX_CONNECTIONS then  -- check connection count
				debug( "to many connections, seconds to wait for next accept:", delay )
				return EV_TIMEOUT, delay  -- timeout...
			else
				return EV_READ  -- accept again
			end
		end
		--vdebug("max connection check ok, accepting...")
		-- luacheck: ignore 231/err
		local client, err = server:accept()    -- try to accept; TODO: check err
		while client do
			if interface._connections >= cfg.MAX_CONNECTIONS then
				client:close( )  -- refuse connection
				debug( "maximal connections reached, refuse client connection; accept delay:", delay )
				return EV_TIMEOUT, delay  -- delay for next accept attempt
			end
			local client_ip, client_port = client:getpeername( )
			interface._connections = interface._connections + 1  -- increase connection count
			local clientinterface = handleclient( client, client_ip, client_port, interface, pattern, listener, sslctx )
			--vdebug( "client id:", clientinterface, "startssl:", startssl )
			if has_luasec and startssl then
				clientinterface:starttls(sslctx, true)
			else
				clientinterface:_start_session( true )
			end
			debug( "accepted incoming client connection from:", client_ip or "<unknown IP>", client_port or "<unknown port>", "to", port or "<unknown port>");

			client, err = server:accept()    -- try to accept again
		end
		return EV_READ
	end

	server:settimeout( 0 )
	setmetatable(interface, interface_mt)
	interfacelist[ interface ] = true
	interface:_start_session()
	return interface
end

local function listen(addr, port, listener, config)
	config = config or {}
	if config.sslctx and not has_luasec then
		debug "fatal error: luasec not found"
		return nil, "luasec not found"
	end
	local server, err = socket.bind( addr, port, cfg.ACCEPT_QUEUE )  -- create server socket
	if not server then
		debug( "creating server socket on "..addr.." port "..port.." failed:", err )
		return nil, err
	end
	local interface = handleserver( server, addr, port, config.read_size, listener, config.tls_ctx, config.tls_direct)  -- new server handler
	debug( "new server created with id:", tostring(interface))
	return interface
end

local function addserver( addr, port, listener, pattern, sslctx )  -- TODO: check arguments
	--vdebug( "creating new tcp server with following parameters:", addr or "nil", port or "nil", sslctx or "nil", startssl or "nil")
	return listen( addr, port, listener, {
		read_size = pattern,
		tls_ctx = sslctx,
		tls_direct = not not sslctx,
	});
end

local function wrapclient( client, ip, port, listeners, pattern, sslctx, extra )
	local interface = handleclient( client, ip, port, nil, pattern, listeners, sslctx, extra )
	interface:_start_connection(sslctx)
	return interface, client
	--function handleclient( client, ip, port, server, pattern, listener, _, sslctx )  -- creates an client interface
end

local function addclient( addr, serverport, listener, pattern, sslctx, typ, extra )
	if sslctx and not has_luasec then
		debug "need luasec, but not available"
		return nil, "luasec not found"
	end
	if not typ then
		local n = inet_pton(addr);
		if not n then return nil, "invalid-ip"; end
		if #n == 16 then
			typ = "tcp6";
		elseif #n == 4 then
			typ = "tcp4";
		end
	end
	local create = socket[typ];
	if type( create ) ~= "function"  then
		return nil, "invalid socket type"
	end
	local client, err = create()  -- creating new socket
	if not client then
		debug( "cannot create socket:", err )
		return nil, err
	end
	client:settimeout( 0 )  -- set nonblocking
	local res, err = client:setpeername( addr, serverport )  -- connect
	if res or ( err == "timeout" ) then
		-- luacheck: ignore 211/port
		local ip, port = client:getsockname( )
		local interface = wrapclient( client, ip, serverport, listener, pattern, sslctx, extra )
		debug( "new connection id:", interface.id )
		return interface, err
	else
		debug( "new connection failed:", err )
		return nil, err
	end
end

local function loop( )  -- starts the event loop
	base:loop( )
	return "quitting";
end

local function newevent( ... )
	return addevent( base, ... )
end

local function closeallservers ( arg )
	for item in pairs( interfacelist ) do
		if item.type == "server" then
			item:close( arg )
		end
	end
end

local function setquitting(yes)
	if yes then
		-- Quit now
		if yes ~= "once" then
			closeallservers();
		end
		base:loopexit();
	end
end

local function get_backend()
	return "libevent " .. base:method();
end

-- We need to hold onto the events to stop them
-- being garbage-collected
local signal_events = {}; -- [signal_num] -> event object
local function hook_signal(signal_num, handler)
	local function _handler()
		local ret = handler();
		if ret ~= false then -- Continue handling this signal?
			return EV_SIGNAL; -- Yes
		end
		return -1; -- Close this event
	end
	signal_events[signal_num] = base:addevent(signal_num, EV_SIGNAL, _handler);
	return signal_events[signal_num];
end

local function link(sender, receiver, buffersize)
	local sender_locked;

	function receiver:ondrain()
		if sender_locked then
			sender:resume();
			sender_locked = nil;
		end
	end

	function sender:onincoming(data)
		receiver:write(data);
		if receiver.writebufferlen >= buffersize then
			sender_locked = true;
			sender:pause();
		end
	end
	sender:set_mode("*a");
end

local function add_task(delay, callback)
	local event_handle;
	event_handle = base:addevent(nil, 0, function ()
		local ret = callback(socket_gettime());
		if ret then
			return 0, ret;
		elseif event_handle then
			return -1;
		end
	end
	, delay);
	return event_handle;
end

local function watchfd(fd, onreadable, onwriteable)
	local handle = {};
	function handle:setflags(r,w)
		if r ~= nil then
			if r and not self.wantread then
				self.wantread = base:addevent(fd, EV_READ, function ()
					onreadable(self);
				end);
			elseif not r and self.wantread then
				self.wantread:close();
				self.wantread = nil;
			end
		end
		if w ~= nil then
			if w and not self.wantwrite then
				self.wantwrite = base:addevent(fd, EV_WRITE, function ()
					onwriteable(self);
				end);
			elseif not r and self.wantread then
				self.wantwrite:close();
				self.wantwrite = nil;
			end
		end
	end
	handle:setflags(onreadable, onwriteable);
	return handle;
end

return {
	cfg = cfg,
	base = base,
	loop = loop,
	link = link,
	event = levent,
	event_base = base,
	addevent = newevent,
	addserver = addserver,
	listen = listen,
	addclient = addclient,
	wrapclient = wrapclient,
	setquitting = setquitting,
	closeall = closeallservers,
	get_backend = get_backend,
	hook_signal = hook_signal,
	add_task = add_task,
	watchfd = watchfd,

	tls_builder = function(basedir)
		return sslconfig._new(tls_impl.new_context, basedir)
	end,

	__NAME = SCRIPT_NAME,
	__DATE = LAST_MODIFIED,
	__AUTHOR = SCRIPT_AUTHOR,
	__VERSION = SCRIPT_VERSION,

}
