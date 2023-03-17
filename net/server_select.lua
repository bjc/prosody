--
-- server.lua by blastbeat of the luadch project
-- Re-used here under the MIT/X Consortium License
--
-- Modifications (C) 2008-2010 Matthew Wild, Waqas Hussain
--

-- // wrapping luadch stuff // --

local use = function( what )
	return _G[ what ]
end

local log, table_concat = require ("prosody.util.logger").init("socket"), table.concat;
local out_put = function (...) return log("debug", table_concat{...}); end
local out_error = function (...) return log("warn", table_concat{...}); end

----------------------------------// DECLARATION //--

--// constants //--

local STAT_UNIT = 1 -- byte

--// lua functions //--

local type = use "type"
local pairs = use "pairs"
local ipairs = use "ipairs"
local tonumber = use "tonumber"
local tostring = use "tostring"

--// lua libs //--

local table = use "table"
local string = use "string"
local coroutine = use "coroutine"

--// lua lib methods //--

local math_min = math.min
local math_huge = math.huge
local table_concat = table.concat
local table_insert = table.insert
local string_sub = string.sub
local coroutine_wrap = coroutine.wrap
local coroutine_yield = coroutine.yield

--// extern libs //--

local luasocket = use "socket" or require "socket"
local luasocket_gettime = luasocket.gettime
local inet = require "prosody.util.net";
local inet_pton = inet.pton;
local sslconfig = require "prosody.util.sslconfig";
local has_luasec, tls_impl = pcall(require, "prosody.net.tls_luasec");

--// extern lib methods //--

local socket_bind = luasocket.bind
local socket_select = luasocket.select

--// functions //--

local id
local loop
local stats
local idfalse
local closeall
local addsocket
local addserver
local listen
local addtimer
local getserver
local wrapserver
local getsettings
local closesocket
local removesocket
local removeserver
local wrapconnection
local changesettings

--// tables //--

local _server
local _readlist
local _timerlist
local _sendlist
local _socketlist
local _closelist
local _readtimes
local _writetimes
local _fullservers

--// simple data types //--

local _
local _readlistlen
local _sendlistlen
local _timerlistlen

local _sendtraffic
local _readtraffic

local _selecttimeout
local _tcpbacklog
local _accepretry

local _starttime
local _currenttime

local _maxsendlen
local _maxreadlen

local _checkinterval
local _sendtimeout
local _readtimeout

local _maxselectlen
local _maxfd

local _maxsslhandshake

----------------------------------// DEFINITION //--

_server = { } -- key = port, value = table; list of listening servers
_readlist = { } -- array with sockets to read from
_sendlist = { } -- array with sockets to write to
_timerlist = { } -- array of timer functions
_socketlist = { } -- key = socket, value = wrapped socket (handlers)
_readtimes = { } -- key = handler, value = timestamp of last data reading
_writetimes = { } -- key = handler, value = timestamp of last data writing/sending
_closelist = { } -- handlers to close
_fullservers = { } -- servers in a paused state while there are too many clients

_readlistlen = 0 -- length of readlist
_sendlistlen = 0 -- length of sendlist
_timerlistlen = 0 -- length of timerlist

_sendtraffic = 0 -- some stats
_readtraffic = 0

_selecttimeout = 1 -- timeout of socket.select
_tcpbacklog = 128 -- some kind of hint to the OS
_accepretry = 10 -- seconds to wait until the next attempt of a full server to accept

_maxsendlen = 51000 * 1024 -- max len of send buffer
_maxreadlen = 25000 * 1024 -- max len of read buffer

_checkinterval = 30 -- interval in secs to check idle clients
_sendtimeout = 60000 -- allowed send idle time in secs
_readtimeout = 14 * 60 -- allowed read idle time in secs

local is_windows = package.config:sub(1,1) == "\\" -- check the directory separator, to determine whether this is Windows
_maxfd = (is_windows and math.huge) or luasocket._SETSIZE or 1024 -- max fd number, limit to 1024 by default to prevent glibc buffer overflow, but not on Windows
_maxselectlen = luasocket._SETSIZE or 1024 -- But this still applies on Windows

_maxsslhandshake = 30 -- max handshake round-trips

----------------------------------// PRIVATE //--

wrapserver = function( listeners, socket, ip, serverport, pattern, sslctx, ssldirect ) -- this function wraps a server -- FIXME Make sure FD < _maxfd

	if socket:getfd() >= _maxfd then
		out_error("server.lua: Disallowed FD number: "..socket:getfd())
		socket:close()
		return nil, "fd-too-large"
	end

	local connections = 0

	local dispatch, disconnect = listeners.onconnect, listeners.ondisconnect

	local accept = socket.accept

	--// public methods of the object //--

	local handler = { }

	handler.shutdown = function( ) end

	handler.ssl = function( )
		return sslctx ~= nil
	end
	handler.sslctx = function( )
		return sslctx
	end
	handler.hosts = {} -- sni
	handler.remove = function( )
		connections = connections - 1
		if handler then
			handler.resume( )
		end
	end
	handler.close = function()
		socket:close( )
		_sendlistlen = removesocket( _sendlist, socket, _sendlistlen )
		_readlistlen = removesocket( _readlist, socket, _readlistlen )
		_server[ip..":"..serverport] = nil;
		_socketlist[ socket ] = nil
		handler = nil
		socket = nil
		--mem_free( )
		out_put "server.lua: closed server handler and removed sockets from list"
	end
	handler.pause = function( hard )
		if not handler.paused then
			_readlistlen = removesocket( _readlist, socket, _readlistlen )
			if hard then
				_socketlist[ socket ] = nil
				socket:close( )
				socket = nil;
			end
			handler.paused = true;
			out_put("server.lua: server [", ip, "]:", serverport, " paused")
		end
	end
	handler.resume = function( )
		if handler.paused then
			if not socket then
				socket = socket_bind( ip, serverport, _tcpbacklog );
				socket:settimeout( 0 )
			end
			_readlistlen = addsocket(_readlist, socket, _readlistlen)
			_socketlist[ socket ] = handler
			_fullservers[ handler ] = nil
			handler.paused = false;
			out_put("server.lua: server [", ip, "]:", serverport, " resumed")
		end
	end
	handler.ip = function( )
		return ip
	end
	handler.serverport = function( )
		return serverport
	end
	handler.socket = function( )
		return socket
	end
	handler.readbuffer = function( )
		if _readlistlen >= _maxselectlen or _sendlistlen >= _maxselectlen then
			handler.pause( )
			_fullservers[ handler ] = _currenttime
			out_put( "server.lua: refused new client connection: server full" )
			return false
		end
		local client, err = accept( socket )	-- try to accept
		if client then
			local ip, clientport = client:getpeername( )
			local handler, client, err = wrapconnection( handler, listeners, client, ip, serverport, clientport, pattern, sslctx, ssldirect ) -- wrap new client socket
			if err then -- error while wrapping ssl socket
				return false
			end
			connections = connections + 1
			out_put( "server.lua: accepted new client connection from ", tostring(ip), ":", tostring(clientport), " to ", tostring(serverport))
			if dispatch and not ssldirect then -- SSL connections will notify onconnect when handshake completes
				return dispatch( handler );
			end
			return;
		elseif err then -- maybe timeout or something else
			out_put( "server.lua: error with new client connection: ", tostring(err) )
			handler.pause( )
			_fullservers[ handler ] = _currenttime
			return false
		end
	end
	return handler
end

wrapconnection = function( server, listeners, socket, ip, serverport, clientport, pattern, sslctx, ssldirect, extra ) -- this function wraps a client to a handler object

	if socket:getfd() >= _maxfd then
		out_error("server.lua: Disallowed FD number: "..socket:getfd()) -- PROTIP: Switch to libevent
		socket:close( ) -- Should we send some kind of error here?
		if server then
			_fullservers[ server ] = _currenttime
			server.pause( )
		end
		return nil, nil, "fd-too-large"
	end
	socket:settimeout( 0 )

	--// local import of socket methods //--

	local send
	local receive
	local shutdown

	--// private closures of the object //--

	local ssl

	local pending

	local dispatch = listeners.onincoming
	local status = listeners.onstatus
	local disconnect = listeners.ondisconnect
	local predrain = listeners.onpredrain
	local drain = listeners.ondrain
	local onreadtimeout = listeners.onreadtimeout;
	local detach = listeners.ondetach

	local bufferqueue = { } -- buffer array
	local bufferqueuelen = 0	-- end of buffer array

	local toclose
	local needtls

	local bufferlen = 0

	local noread = false
	local nosend = false

	local sendtraffic, readtraffic = 0, 0

	local maxsendlen = _maxsendlen
	local maxreadlen = _maxreadlen

	--// public methods of the object //--

	local handler = bufferqueue -- saves a table ^_^

	handler.extra = extra
	if extra then
		handler.servername = extra.servername
	end

	handler.dispatch = function( )
		return dispatch
	end
	handler.disconnect = function( )
		return disconnect
	end
	handler.onreadtimeout = onreadtimeout;

	handler.setlistener = function( self, listeners, data )
		if detach then
			detach(self) -- Notify listener that it is no longer responsible for this connection
		end
		dispatch = listeners.onincoming
		disconnect = listeners.ondisconnect
		status = listeners.onstatus
		predrain = listeners.onpredrain
		drain = listeners.ondrain
		handler.onreadtimeout = listeners.onreadtimeout
		detach = listeners.ondetach
		if listeners.onattach then
			listeners.onattach(self, data)
		end
	end
	handler._setpending = function( )
		pending = true
	end
	handler.getstats = function( )
		return readtraffic, sendtraffic
	end
	handler.ssl = function( )
		return ssl
	end
	handler.sslctx = function ( )
		return sslctx
	end
	handler.ssl_info = function( )
		return socket.info and socket:info()
	end
	handler.ssl_peercertificate = function( )
		if not socket.getpeercertificate then return nil, "not-implemented"; end
		return socket:getpeercertificate()
	end
	handler.ssl_peerverification = function( )
		if not socket.getpeerverification then return nil, { { "Chain verification not supported" } }; end
		return socket:getpeerverification();
	end
	handler.ssl_peerfinished = function( )
		if not socket.getpeerfinished then return nil, "not-implemented"; end
		return socket:getpeerfinished();
	end
	handler.send = function( _, data, i, j )
		return send( socket, data, i, j )
	end
	handler.receive = function( pattern, prefix )
		return receive( socket, pattern, prefix )
	end
	handler.shutdown = function( pattern )
		return shutdown( socket, pattern )
	end
	handler.setoption = function (self, option, value)
		if socket.setoption then
			return socket:setoption(option, value);
		end
		return false, "setoption not implemented";
	end
	handler.force_close = function ( self, err )
		if bufferqueuelen ~= 0 then
			out_put("server.lua: discarding unwritten data for ", tostring(ip), ":", tostring(clientport))
			bufferqueuelen = 0;
		end
		return self:close(err);
	end
	handler.close = function( self, err )
		if not handler then return true; end
		_readlistlen = removesocket( _readlist, socket, _readlistlen )
		_readtimes[ handler ] = nil
		if bufferqueuelen ~= 0 then
			handler:sendbuffer() -- Try now to send any outstanding data
			if bufferqueuelen ~= 0 then -- Still not empty, so we'll try again later
				if handler then
					handler.write = nil -- ... but no further writing allowed
				end
				toclose = true
				return false
			end
		end
		if socket then
			_ = shutdown and shutdown( socket )
			socket:close( )
			_sendlistlen = removesocket( _sendlist, socket, _sendlistlen )
			_socketlist[ socket ] = nil
			socket = nil
		else
			out_put "server.lua: socket already closed"
		end
		if handler then
			_writetimes[ handler ] = nil
			_closelist[ handler ] = nil
			local _handler = handler;
			handler = nil
			if disconnect then
				disconnect(_handler, err or false);
				disconnect = nil
			end
		end
		if server then
			server.remove( )
		end
		out_put "server.lua: closed client handler and removed socket from list"
		return true
	end
	handler.server = function ( )
		return server
	end
	handler.ip = function( )
		return ip
	end
	handler.serverport = function( )
		return serverport
	end
	handler.clientport = function( )
		return clientport
	end
	handler.port = handler.clientport -- COMPAT server_event
	local write = function( self, data )
		if not handler then return false end
		bufferlen = bufferlen + #data
		if bufferlen > maxsendlen then
			_closelist[ handler ] = "send buffer exceeded"	 -- cannot close the client at the moment, have to wait to the end of the cycle
			return false
		elseif not nosend and socket and not _sendlist[ socket ] then
			_sendlistlen = addsocket(_sendlist, socket, _sendlistlen)
		end
		bufferqueuelen = bufferqueuelen + 1
		bufferqueue[ bufferqueuelen ] = data
		if handler then
			_writetimes[ handler ] = _writetimes[ handler ] or _currenttime
		end
		return true
	end
	handler.write = write
	handler.bufferqueue = function( self )
		return bufferqueue
	end
	handler.socket = function( self )
		return socket
	end
	handler.set_mode = function( self, new )
		pattern = new or pattern
		return pattern
	end
	handler.set_send = function ( self, newsend )
		send = newsend or send
		return send
	end
	handler.bufferlen = function( self, readlen, sendlen )
		maxsendlen = sendlen or maxsendlen
		maxreadlen = readlen or maxreadlen
		return bufferlen, maxreadlen, maxsendlen
	end
	handler.lock_read = function (self, switch)
		out_error( "server.lua, lock_read() is deprecated, use pause() and resume()" )
		if switch == true then
			return self:pause()
		elseif switch == false then
			return self:resume()
		end
		return noread
	end
	handler.pause = function (self)
		local tmp = _readlistlen
		_readlistlen = removesocket( _readlist, socket, _readlistlen )
		_readtimes[ handler ] = nil
		if _readlistlen ~= tmp then
			noread = true
		end
		return noread;
	end
	handler.resume = function (self)
		if noread then
			noread = false
			_readlistlen = addsocket(_readlist, socket, _readlistlen)
			_readtimes[ handler ] = _currenttime
		end
		return noread;
	end
	handler.lock = function( self, switch )
		out_error( "server.lua, lock() is deprecated" )
		handler.lock_read (self, switch)
		if switch == true then
			handler.pause_writes (self)
		elseif switch == false then
			handler.resume_writes (self)
		end
		return noread, nosend
	end
	handler.pause_writes = function (self)
		local tmp = _sendlistlen
		_sendlistlen = removesocket( _sendlist, socket, _sendlistlen )
		_writetimes[ handler ] = nil
		nosend = true
	end
	handler.resume_writes = function (self)
		nosend = false
		if bufferlen > 0 and socket then
			_sendlistlen = addsocket(_sendlist, socket, _sendlistlen)
		end
	end

	local _readbuffer = function( ) -- this function reads data
		local buffer, err, part = receive( socket, pattern )	-- receive buffer with "pattern"
		if not err or (err == "wantread" or err == "timeout") then -- received something
			local buffer = buffer or part or ""
			local len = #buffer
			if len > maxreadlen then
				handler:close( "receive buffer exceeded" )
				return false
			end
			local count = len * STAT_UNIT
			readtraffic = readtraffic + count
			_readtraffic = _readtraffic + count
			_readtimes[ handler ] = _currenttime
			--out_put( "server.lua: read data '", buffer:gsub("[^%w%p ]", "."), "', error: ", err )
			if pending then -- connection established
				pending = nil
				if listeners.onconnect then
					listeners.onconnect(handler)
				end
			end
			return dispatch( handler, buffer, err )
		else	-- connections was closed or fatal error
			out_put( "server.lua: client ", tostring(ip), ":", tostring(clientport), " read error: ", tostring(err) )
			_ = handler and handler:force_close( err )
			return false
		end
	end
	local _sendbuffer = function( ) -- this function sends data
		local succ, err, byte, buffer, count;
		if socket then
			if pending then
				pending = nil
				if listeners.onconnect then
					listeners.onconnect(handler);
				end
			end
			if predrain then
				predrain(handler);
			end
			buffer = table_concat( bufferqueue, "", 1, bufferqueuelen )
			succ, err, byte = send( socket, buffer, 1, bufferlen )
			count = ( succ or byte or 0 ) * STAT_UNIT
			sendtraffic = sendtraffic + count
			_sendtraffic = _sendtraffic + count
			for i = bufferqueuelen,1,-1 do
				bufferqueue[ i ] = nil
			end
			--out_put( "server.lua: sended '", buffer, "', bytes: ", tostring(succ), ", error: ", tostring(err), ", part: ", tostring(byte), ", to: ", tostring(ip), ":", tostring(clientport) )
		else
			succ, err, count = false, "unexpected close", 0;
		end
		if succ then	-- sending successful
			bufferqueuelen = 0
			bufferlen = 0
			_sendlistlen = removesocket( _sendlist, socket, _sendlistlen ) -- delete socket from writelist
			_writetimes[ handler ] = nil
			if drain then
				drain(handler)
			end
			_ = needtls and handler:starttls(nil)
			_ = toclose and handler:force_close( )
			return true
		elseif byte and ( err == "timeout" or err == "wantwrite" ) then -- want write
			buffer = string_sub( buffer, byte + 1, bufferlen ) -- new buffer
			bufferqueue[ 1 ] = buffer	 -- insert new buffer in queue
			bufferqueuelen = 1
			bufferlen = bufferlen - byte
			_writetimes[ handler ] = _currenttime
			return true
		else	-- connection was closed during sending or fatal error
			out_put( "server.lua: client ", tostring(ip), ":", tostring(clientport), " write error: ", tostring(err) )
			_ = handler and handler:force_close( err )
			return false
		end
	end

	-- Set the sslctx
	local handshake;
	function handler.set_sslctx(self, new_sslctx)
		sslctx = new_sslctx;
		local read, wrote
		handshake = coroutine_wrap( function( client ) -- create handshake coroutine
				local err
				for _ = 1, _maxsslhandshake do
					_sendlistlen = ( wrote and removesocket( _sendlist, client, _sendlistlen ) ) or _sendlistlen
					_readlistlen = ( read and removesocket( _readlist, client, _readlistlen ) ) or _readlistlen
					read, wrote = nil, nil
					_, err = client:dohandshake( )
					if not err then
						out_put( "server.lua: ssl handshake done" )
						handler.readbuffer = _readbuffer	-- when handshake is done, replace the handshake function with regular functions
						handler.sendbuffer = _sendbuffer
						_ = status and status( handler, "ssl-handshake-complete" )
						if self.autostart_ssl and listeners.onconnect then
							listeners.onconnect(self);
							if bufferqueuelen ~= 0 then
								_sendlistlen = addsocket(_sendlist, client, _sendlistlen)
							end
						end
						_readlistlen = addsocket(_readlist, client, _readlistlen)
						return true
					else
						if err == "wantwrite" then
							_sendlistlen = addsocket(_sendlist, client, _sendlistlen)
							wrote = true
						elseif err == "wantread" then
							_readlistlen = addsocket(_readlist, client, _readlistlen)
							read = true
						else
							break;
						end
						err = nil;
						coroutine_yield( ) -- handshake not finished
					end
				end
				err = ( err or "handshake too long" );
				out_put( "server.lua: ", err );
				_ = handler and handler:force_close(err)
				return false, err -- handshake failed
			end
		)
	end
	if has_luasec then
		handler.starttls = function( self, _sslctx)
			if _sslctx then
				handler:set_sslctx(_sslctx);
			end
			if bufferqueuelen > 0 then
				out_put "server.lua: we need to do tls, but delaying until send buffer empty"
				needtls = true
				return
			end
			out_put( "server.lua: attempting to start tls on " .. tostring( socket ) )
			local oldsocket, err = socket
			socket, err = sslctx:wrap(socket)	-- wrap socket

			if not socket then
				out_put( "server.lua: error while starting tls on client: ", tostring(err or "unknown error") )
				return nil, err -- fatal error
			end

			if socket.sni then
				if self.servername then
					socket:sni(self.servername);
				elseif next(sslctx._sni_contexts) ~= nil then
					socket:sni(sslctx._sni_contexts, true);
				end
			end

			socket:settimeout( 0 )

			-- add the new socket to our system
			send = socket.send
			receive = socket.receive
			shutdown = id
			_socketlist[ socket ] = handler
			_readlistlen = addsocket(_readlist, socket, _readlistlen)

			-- remove traces of the old socket
			_readlistlen = removesocket( _readlist, oldsocket, _readlistlen )
			_sendlistlen = removesocket( _sendlist, oldsocket, _sendlistlen )
			_socketlist[ oldsocket ] = nil

			handler.starttls = nil
			needtls = nil

			-- Secure now (if handshake fails connection will close)
			ssl = true

			handler.readbuffer = handshake
			handler.sendbuffer = handshake
			return handshake( socket ) -- do handshake
		end
	end

	handler.readbuffer = _readbuffer
	handler.sendbuffer = _sendbuffer
	send = socket.send
	receive = socket.receive
	shutdown = ( ssl and id ) or socket.shutdown

	_socketlist[ socket ] = handler
	_readlistlen = addsocket(_readlist, socket, _readlistlen)

	if sslctx and ssldirect and has_luasec then
		out_put "server.lua: auto-starting ssl negotiation..."
		handler.autostart_ssl = true;
		local ok, err = handler:starttls(sslctx);
		if ok == false then
			return nil, nil, err
		end
	end

	return handler, socket
end

id = function( )
end

idfalse = function( )
	return false
end

addsocket = function( list, socket, len )
	if not list[ socket ] then
		len = len + 1
		list[ len ] = socket
		list[ socket ] = len
	end
	return len;
end

removesocket = function( list, socket, len )	-- this function removes sockets from a list ( copied from copas )
	local pos = list[ socket ]
	if pos then
		list[ socket ] = nil
		local last = list[ len ]
		list[ len ] = nil
		if last ~= socket then
			list[ last ] = pos
			list[ pos ] = last
		end
		return len - 1
	end
	return len
end

closesocket = function( socket )
	_sendlistlen = removesocket( _sendlist, socket, _sendlistlen )
	_readlistlen = removesocket( _readlist, socket, _readlistlen )
	_socketlist[ socket ] = nil
	socket:close( )
	--mem_free( )
end

local function link(sender, receiver, buffersize)
	local sender_locked;
	local _sendbuffer = receiver.sendbuffer;
	function receiver.sendbuffer()
		_sendbuffer(receiver);
		if sender_locked and receiver.bufferlen() < buffersize then
			sender:lock_read(false); -- Unlock now
			sender_locked = nil;
		end
	end

	local _readbuffer = sender.readbuffer;
	function sender.readbuffer()
		_readbuffer();
		if not sender_locked and receiver.bufferlen() >= buffersize then
			sender_locked = true;
			sender:lock_read(true);
		end
	end
	sender:set_mode("*a");
end

----------------------------------// PUBLIC //--

listen = function ( addr, port, listeners, config )
	addr = addr or "*"
	config = config or {}
	local err
	local sslctx = config.tls_ctx;
	local ssldirect = config.tls_direct;
	local pattern = config.read_size;
	if type( listeners ) ~= "table" then
		err = "invalid listener table"
	elseif type ( addr ) ~= "string" then
		err = "invalid address"
	elseif type( port ) ~= "number" or not ( port >= 0 and port <= 65535 ) then
		err = "invalid port"
	elseif _server[ addr..":"..port ] then
		err = "listeners on '[" .. addr .. "]:" .. port .. "' already exist"
	elseif sslctx and not has_luasec then
		err = "luasec not found"
	end
	if err then
		out_error( "server.lua, [", addr, "]:", port, ": ", err )
		return nil, err
	end
	local server, err = socket_bind( addr, port, _tcpbacklog )
	if err then
		out_error( "server.lua, [", addr, "]:", port, ": ", err )
		return nil, err
	end
	local handler, err = wrapserver( listeners, server, addr, port, pattern, sslctx, ssldirect ) -- wrap new server socket
	if not handler then
		server:close( )
		return nil, err
	end
	server:settimeout( 0 )
	_readlistlen = addsocket(_readlist, server, _readlistlen)
	_server[ addr..":"..port ] = handler
	_socketlist[ server ] = handler
	out_put( "server.lua: new "..(sslctx and "ssl " or "").."server listener on '[", addr, "]:", port, "'" )
	return handler
end

addserver = function( addr, port, listeners, pattern, sslctx ) -- this function provides a way for other scripts to reg a server
	return listen(addr, port, listeners, {
		read_size = pattern;
		tls_ctx = sslctx;
		tls_direct = sslctx and true or false;
	});
end

getserver = function ( addr, port )
	return _server[ addr..":"..port ];
end

removeserver = function( addr, port )
	local handler = _server[ addr..":"..port ]
	if not handler then
		return nil, "no server found on '[" .. addr .. "]:" .. tostring( port ) .. "'"
	end
	handler:close( )
	_server[ addr..":"..port ] = nil
	return true
end

closeall = function( )
	for _, handler in pairs( _socketlist ) do
		handler:close( )
		_socketlist[ _ ] = nil
	end
	_readlistlen = 0
	_sendlistlen = 0
	_timerlistlen = 0
	_server = { }
	_readlist = { }
	_sendlist = { }
	_timerlist = { }
	_socketlist = { }
	--mem_free( )
end

getsettings = function( )
	return {
		select_timeout = _selecttimeout;
		tcp_backlog = _tcpbacklog;
		max_send_buffer_size = _maxsendlen;
		max_receive_buffer_size = _maxreadlen;
		select_idle_check_interval = _checkinterval;
		send_timeout = _sendtimeout;
		read_timeout = _readtimeout;
		max_connections = _maxselectlen;
		max_ssl_handshake_roundtrips = _maxsslhandshake;
		highest_allowed_fd = _maxfd;
		accept_retry_interval = _accepretry;
	}
end

changesettings = function( new )
	if type( new ) ~= "table" then
		return nil, "invalid settings table"
	end
	_selecttimeout = tonumber( new.select_timeout ) or _selecttimeout
	_maxsendlen = tonumber( new.max_send_buffer_size ) or _maxsendlen
	_maxreadlen = tonumber( new.max_receive_buffer_size ) or _maxreadlen
	_checkinterval = tonumber( new.select_idle_check_interval ) or _checkinterval
	_tcpbacklog = tonumber( new.tcp_backlog ) or _tcpbacklog
	_sendtimeout = tonumber( new.send_timeout ) or _sendtimeout
	_readtimeout = tonumber( new.read_timeout ) or _readtimeout
	_accepretry = tonumber( new.accept_retry_interval ) or _accepretry
	_maxselectlen = new.max_connections or _maxselectlen
	_maxsslhandshake = new.max_ssl_handshake_roundtrips or _maxsslhandshake
	_maxfd = new.highest_allowed_fd or _maxfd
	return true
end

addtimer = function( listener )
	if type( listener ) ~= "function" then
		return nil, "invalid listener function"
	end
	_timerlistlen = _timerlistlen + 1
	_timerlist[ _timerlistlen ] = listener
	return true
end

local add_task do
	local data = {};
	local new_data = {};

	function add_task(delay, callback)
		local current_time = luasocket_gettime();
		delay = delay + current_time;
		if delay >= current_time then
			table_insert(new_data, {delay, callback});
		else
			local r = callback(current_time);
			if r and type(r) == "number" then
				return add_task(r, callback);
			end
		end
	end

	addtimer(function(current_time)
		if #new_data > 0 then
			for _, d in pairs(new_data) do
				table_insert(data, d);
			end
			new_data = {};
		end

		local next_time = math_huge;
		for i, d in pairs(data) do
			local t, callback = d[1], d[2];
			if t <= current_time then
				data[i] = nil;
				local r = callback(current_time);
				if type(r) == "number" then
					add_task(r, callback);
					next_time = math_min(next_time, r);
				end
			else
				next_time = math_min(next_time, t - current_time);
			end
		end
		return next_time;
	end);
end

stats = function( )
	return _readtraffic, _sendtraffic, _readlistlen, _sendlistlen, _timerlistlen
end

local quitting;

local function setquitting(quit)
	quitting = quit;
end

loop = function(once) -- this is the main loop of the program
	if quitting then return "quitting"; end
	if once then quitting = "once"; end
	_currenttime = luasocket_gettime( )
	repeat
		-- Fire timers
	local next_timer_time = math_huge;
		for i = 1, _timerlistlen do
			local t = _timerlist[ i ]( _currenttime ) -- fire timers
			if t then next_timer_time = math_min(next_timer_time, t); end
		end

		local read, write, err = socket_select( _readlist, _sendlist, math_min(_selecttimeout, next_timer_time) )
		for _, socket in ipairs( read ) do -- receive data
			local handler = _socketlist[ socket ]
			if handler then
				handler:readbuffer( )
			else
				closesocket( socket )
				out_put "server.lua: found no handler and closed socket (readlist)" -- this can happen
			end
		end
		for _, socket in ipairs( write ) do -- send data waiting in writequeues
			local handler = _socketlist[ socket ]
			if handler then
				handler:sendbuffer( )
			else
				closesocket( socket )
				out_put "server.lua: found no handler and closed socket (writelist)"	-- this should not happen
			end
		end
		for handler, err in pairs( _closelist ) do
			handler.disconnect( )( handler, err )
			handler:force_close()	 -- forced disconnect
			_closelist[ handler ] = nil;
		end
		_currenttime = luasocket_gettime( )

		-- Check for socket timeouts
		if _currenttime - _starttime > _checkinterval then
			_starttime = _currenttime
			for handler, timestamp in pairs( _writetimes ) do
				if _currenttime - timestamp > _sendtimeout then
					handler.disconnect( )( handler, "send timeout" )
					handler:force_close()	 -- forced disconnect
				end
			end
			for handler, timestamp in pairs( _readtimes ) do
				if _currenttime - timestamp > _readtimeout then
					if not(handler.onreadtimeout) or handler:onreadtimeout() ~= true then
						handler.disconnect( )( handler, "read timeout" )
						handler:close( )	-- forced disconnect?
					else
						_readtimes[ handler ] = _currenttime -- reset timer
					end
				end
			end
		end

		for server, paused_time in pairs( _fullservers ) do
			if _currenttime - paused_time > _accepretry then
				_fullservers[ server ] = nil;
				server.resume();
			end
		end
	until quitting;
	if quitting == "once" then quitting = nil; return; end
	closeall();
	return "quitting"
end

local function step()
	return loop(true);
end

local function get_backend()
	return "select";
end

--// EXPERIMENTAL //--

local wrapclient = function( socket, ip, serverport, listeners, pattern, sslctx, extra )
	local handler, socket, err = wrapconnection( nil, listeners, socket, ip, serverport, "clientport", pattern, sslctx, sslctx, extra)
	if not handler then return nil, err end
	_socketlist[ socket ] = handler
	if not sslctx then
		handler._setpending()
		_readlistlen = addsocket(_readlist, socket, _readlistlen)
		_sendlistlen = addsocket(_sendlist, socket, _sendlistlen)
	end
	return handler, socket
end

local addclient = function( address, port, listeners, pattern, sslctx, typ, extra )
	local err
	if type( listeners ) ~= "table" then
		err = "invalid listener table"
	elseif type ( address ) ~= "string" then
		err = "invalid address"
	elseif type( port ) ~= "number" or not ( port >= 0 and port <= 65535 ) then
		err = "invalid port"
	elseif sslctx and not has_luasec then
		err = "luasec not found"
	end
	if not typ then
		local n = inet_pton(address);
		if not n then return nil, "invalid-ip"; end
		if #n == 16 then
			typ = "tcp6";
		elseif #n == 4 then
			typ = "tcp4";
		end
	end
	local create = luasocket[typ];
	if type( create ) ~= "function"  then
		err = "invalid socket type"
	end

	if err then
		out_error( "server.lua, addclient: ", err )
		return nil, err
	end

	local client, err = create( )
	if err then
		return nil, err
	end
	client:settimeout( 0 )
	local ok, err = client:setpeername( address, port )
	if ok or err == "timeout" or err == "Operation already in progress" then
		return wrapclient( client, address, port, listeners, pattern, sslctx, extra )
	else
		return nil, err
	end
end

local closewatcher = function (handler)
	local socket = handler.conn;
	_sendlistlen = removesocket( _sendlist, socket, _sendlistlen )
	_readlistlen = removesocket( _readlist, socket, _readlistlen )
	_socketlist[ socket ] = nil
end;

local addremove = function (handler, read, send)
	local socket = handler.conn
	_socketlist[ socket ] = handler
	if read ~= nil then
		if read then
			_readlistlen = addsocket( _readlist, socket, _readlistlen )
		else
			_sendlistlen = removesocket( _sendlist, socket, _sendlistlen )
		end
	end
	if send ~= nil then
		if send then
			_sendlistlen = addsocket( _sendlist, socket, _sendlistlen )
		else
			_readlistlen = removesocket( _readlist, socket, _readlistlen )
		end
	end
end

local watchfd = function ( fd, onreadable, onwriteable )
	local socket = fd
	if type(fd) == "number" then
		socket = { getfd = function () return fd; end }
	end
	local handler = {
		conn = socket;
		readbuffer = onreadable or id;
		sendbuffer = onwriteable or id;
		close = closewatcher;
		setflags = addremove;
	};
	addremove( handler, onreadable, onwriteable )
	return handler
end

----------------------------------// BEGIN //--

use "setmetatable" ( _socketlist, { __mode = "k" } )
use "setmetatable" ( _readtimes, { __mode = "k" } )
use "setmetatable" ( _writetimes, { __mode = "k" } )

_starttime = luasocket_gettime( )

local function setlogger(new_logger)
	local old_logger = log;
	if new_logger then
		log = new_logger;
	end
	return old_logger;
end

----------------------------------// PUBLIC INTERFACE //--

return {
	_addtimer = addtimer,
	add_task = add_task;

	addclient = addclient,
	wrapclient = wrapclient,
	watchfd = watchfd,

	loop = loop,
	link = link,
	step = step,
	stats = stats,
	closeall = closeall,
	addserver = addserver,
	listen = listen,
	getserver = getserver,
	setlogger = setlogger,
	getsettings = getsettings,
	setquitting = setquitting,
	removeserver = removeserver,
	get_backend = get_backend,
	changesettings = changesettings,

	tls_builder = function(basedir)
		return sslconfig._new(tls_impl.new_context, basedir)
	end,
}
