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

local log, table_concat = require ("util.logger").init("socket"), table.concat;
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

local os = use "os"
local table = use "table"
local string = use "string"
local coroutine = use "coroutine"

--// lua lib methods //--

local os_difftime = os.difftime
local math_min = math.min
local math_huge = math.huge
local table_concat = table.concat
local string_sub = string.sub
local coroutine_wrap = coroutine.wrap
local coroutine_yield = coroutine.yield

--// extern libs //--

local luasec = use "ssl"
local luasocket = use "socket" or require "socket"
local luasocket_gettime = luasocket.gettime

--// extern lib methods //--

local ssl_wrap = ( luasec and luasec.wrap )
local socket_bind = luasocket.bind
local socket_sleep = luasocket.sleep
local socket_select = luasocket.select

--// functions //--

local id
local loop
local stats
local idfalse
local closeall
local addsocket
local addserver
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

--// simple data types //--

local _
local _readlistlen
local _sendlistlen
local _timerlistlen

local _sendtraffic
local _readtraffic

local _selecttimeout
local _sleeptime
local _tcpbacklog

local _starttime
local _currenttime

local _maxsendlen
local _maxreadlen

local _checkinterval
local _sendtimeout
local _readtimeout

local _timer

local _maxselectlen
local _maxfd

local _maxsslhandshake

----------------------------------// DEFINITION //--

_server = { } -- key = port, value = table; list of listening servers
_readlist = { } -- array with sockets to read from
_sendlist = { } -- arrary with sockets to write to
_timerlist = { } -- array of timer functions
_socketlist = { } -- key = socket, value = wrapped socket (handlers)
_readtimes = { } -- key = handler, value = timestamp of last data reading
_writetimes = { } -- key = handler, value = timestamp of last data writing/sending
_closelist = { } -- handlers to close

_readlistlen = 0 -- length of readlist
_sendlistlen = 0 -- length of sendlist
_timerlistlen = 0 -- lenght of timerlist

_sendtraffic = 0 -- some stats
_readtraffic = 0

_selecttimeout = 1 -- timeout of socket.select
_sleeptime = 0 -- time to wait at the end of every loop
_tcpbacklog = 128 -- some kind of hint to the OS

_maxsendlen = 51000 * 1024 -- max len of send buffer
_maxreadlen = 25000 * 1024 -- max len of read buffer

_checkinterval = 30 -- interval in secs to check idle clients
_sendtimeout = 60000 -- allowed send idle time in secs
_readtimeout = 6 * 60 * 60 -- allowed read idle time in secs

local is_windows = package.config:sub(1,1) == "\\" -- check the directory separator, to detemine whether this is Windows
_maxfd = (is_windows and math.huge) or luasocket._SETSIZE or 1024 -- max fd number, limit to 1024 by default to prevent glibc buffer overflow, but not on Windows
_maxselectlen = luasocket._SETSIZE or 1024 -- But this still applies on Windows

_maxsslhandshake = 30 -- max handshake round-trips

----------------------------------// PRIVATE //--

wrapserver = function( listeners, socket, ip, serverport, pattern, sslctx ) -- this function wraps a server -- FIXME Make sure FD < _maxfd

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
			handler.paused = false;
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
			out_put( "server.lua: refused new client connection: server full" )
			return false
		end
		local client, err = accept( socket )	-- try to accept
		if client then
			local ip, clientport = client:getpeername( )
			local handler, client, err = wrapconnection( handler, listeners, client, ip, serverport, clientport, pattern, sslctx ) -- wrap new client socket
			if err then -- error while wrapping ssl socket
				return false
			end
			connections = connections + 1
			out_put( "server.lua: accepted new client connection from ", tostring(ip), ":", tostring(clientport), " to ", tostring(serverport))
			if dispatch and not sslctx then -- SSL connections will notify onconnect when handshake completes
				return dispatch( handler );
			end
			return;
		elseif err then -- maybe timeout or something else
			out_put( "server.lua: error with new client connection: ", tostring(err) )
			return false
		end
	end
	return handler
end

wrapconnection = function( server, listeners, socket, ip, serverport, clientport, pattern, sslctx ) -- this function wraps a client to a handler object

	if socket:getfd() >= _maxfd then
		out_error("server.lua: Disallowed FD number: "..socket:getfd()) -- PROTIP: Switch to libevent
		socket:close( ) -- Should we send some kind of error here?
		server.pause( )
		return nil, nil, "fd-too-large"
	end
	socket:settimeout( 0 )

	--// local import of socket methods //--

	local send
	local receive
	local shutdown

	--// private closures of the object //--

	local ssl

	local dispatch = listeners.onincoming
	local status = listeners.onstatus
	local disconnect = listeners.ondisconnect
	local drain = listeners.ondrain

	local bufferqueue = { } -- buffer array
	local bufferqueuelen = 0	-- end of buffer array

	local toclose
	local fatalerror
	local needtls

	local bufferlen = 0

	local noread = false
	local nosend = false

	local sendtraffic, readtraffic = 0, 0

	local maxsendlen = _maxsendlen
	local maxreadlen = _maxreadlen

	--// public methods of the object //--

	local handler = bufferqueue -- saves a table ^_^

	handler.dispatch = function( )
		return dispatch
	end
	handler.disconnect = function( )
		return disconnect
	end
	handler.setlistener = function( self, listeners )
		dispatch = listeners.onincoming
		disconnect = listeners.ondisconnect
		status = listeners.onstatus
		drain = listeners.ondrain
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
			handler.sendbuffer() -- Try now to send any outstanding data
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
	handler.ip = function( )
		return ip
	end
	handler.serverport = function( )
		return serverport
	end
	handler.clientport = function( )
		return clientport
	end
	local write = function( self, data )
		bufferlen = bufferlen + #data
		if bufferlen > maxsendlen then
			_closelist[ handler ] = "send buffer exceeded"	 -- cannot close the client at the moment, have to wait to the end of the cycle
			handler.write = idfalse -- dont write anymore
			return false
		elseif socket and not _sendlist[ socket ] then
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
	--TODO: Deprecate
	handler.lock_read = function (self, switch)
		if switch == true then
			local tmp = _readlistlen
			_readlistlen = removesocket( _readlist, socket, _readlistlen )
			_readtimes[ handler ] = nil
			if _readlistlen ~= tmp then
				noread = true
			end
		elseif switch == false then
			if noread then
				noread = false
				_readlistlen = addsocket(_readlist, socket, _readlistlen)
				_readtimes[ handler ] = _currenttime
			end
		end
		return noread
	end
	handler.pause = function (self)
		return self:lock_read(true);
	end
	handler.resume = function (self)
		return self:lock_read(false);
	end
	handler.lock = function( self, switch )
		handler.lock_read (switch)
		if switch == true then
			handler.write = idfalse
			local tmp = _sendlistlen
			_sendlistlen = removesocket( _sendlist, socket, _sendlistlen )
			_writetimes[ handler ] = nil
			if _sendlistlen ~= tmp then
				nosend = true
			end
		elseif switch == false then
			handler.write = write
			if nosend then
				nosend = false
				write( "" )
			end
		end
		return noread, nosend
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
			return dispatch( handler, buffer, err )
		else	-- connections was closed or fatal error
			out_put( "server.lua: client ", tostring(ip), ":", tostring(clientport), " read error: ", tostring(err) )
			fatalerror = true
			_ = handler and handler:force_close( err )
			return false
		end
	end
	local _sendbuffer = function( ) -- this function sends data
		local succ, err, byte, buffer, count;
		if socket then
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
		if succ then	-- sending succesful
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
			fatalerror = true
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
				for i = 1, _maxsslhandshake do
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
				out_put( "server.lua: ssl handshake error: ", tostring(err or "handshake too long") )
				_ = handler and handler:force_close("ssl handshake failed")
				return false, err -- handshake failed
			end
		)
	end
	if luasec then
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
			socket, err = ssl_wrap( socket, sslctx )	-- wrap socket
			if not socket then
				out_put( "server.lua: error while starting tls on client: ", tostring(err or "unknown error") )
				return nil, err -- fatal error
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

	if sslctx and luasec then
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
		_sendbuffer();
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
end

----------------------------------// PUBLIC //--

addserver = function( addr, port, listeners, pattern, sslctx ) -- this function provides a way for other scripts to reg a server
	local err
	if type( listeners ) ~= "table" then
		err = "invalid listener table"
	end
	if type( port ) ~= "number" or not ( port >= 0 and port <= 65535 ) then
		err = "invalid port"
	elseif _server[ addr..":"..port ] then
		err = "listeners on '[" .. addr .. "]:" .. port .. "' already exist"
	elseif sslctx and not luasec then
		err = "luasec not found"
	end
	if err then
		out_error( "server.lua, [", addr, "]:", port, ": ", err )
		return nil, err
	end
	addr = addr or "*"
	local server, err = socket_bind( addr, port, _tcpbacklog )
	if err then
		out_error( "server.lua, [", addr, "]:", port, ": ", err )
		return nil, err
	end
	local handler, err = wrapserver( listeners, server, addr, port, pattern, sslctx ) -- wrap new server socket
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
		select_sleep_time = _sleeptime;
		tcp_backlog = _tcpbacklog;
		max_send_buffer_size = _maxsendlen;
		max_receive_buffer_size = _maxreadlen;
		select_idle_check_interval = _checkinterval;
		send_timeout = _sendtimeout;
		read_timeout = _readtimeout;
		max_connections = _maxselectlen;
		max_ssl_handshake_roundtrips = _maxsslhandshake;
		highest_allowed_fd = _maxfd;
	}
end

changesettings = function( new )
	if type( new ) ~= "table" then
		return nil, "invalid settings table"
	end
	_selecttimeout = tonumber( new.select_timeout ) or _selecttimeout
	_sleeptime = tonumber( new.select_sleep_time ) or _sleeptime
	_maxsendlen = tonumber( new.max_send_buffer_size ) or _maxsendlen
	_maxreadlen = tonumber( new.max_receive_buffer_size ) or _maxreadlen
	_checkinterval = tonumber( new.select_idle_check_interval ) or _checkinterval
	_tcpbacklog = tonumber( new.tcp_backlog ) or _tcpbacklog
	_sendtimeout = tonumber( new.send_timeout ) or _sendtimeout
	_readtimeout = tonumber( new.read_timeout ) or _readtimeout
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

stats = function( )
	return _readtraffic, _sendtraffic, _readlistlen, _sendlistlen, _timerlistlen
end

local quitting;

local function setquitting(quit)
	quitting = not not quit;
end

loop = function(once) -- this is the main loop of the program
	if quitting then return "quitting"; end
	if once then quitting = "once"; end
	local next_timer_time = math_huge;
	repeat
		local read, write, err = socket_select( _readlist, _sendlist, math_min(_selecttimeout, next_timer_time) )
		for i, socket in ipairs( write ) do -- send data waiting in writequeues
			local handler = _socketlist[ socket ]
			if handler then
				handler.sendbuffer( )
			else
				closesocket( socket )
				out_put "server.lua: found no handler and closed socket (writelist)"	-- this should not happen
			end
		end
		for i, socket in ipairs( read ) do -- receive data
			local handler = _socketlist[ socket ]
			if handler then
				handler.readbuffer( )
			else
				closesocket( socket )
				out_put "server.lua: found no handler and closed socket (readlist)" -- this can happen
			end
		end
		for handler, err in pairs( _closelist ) do
			handler.disconnect( )( handler, err )
			handler:force_close()	 -- forced disconnect
			_closelist[ handler ] = nil;
		end
		_currenttime = luasocket_gettime( )

		-- Check for socket timeouts
		local difftime = os_difftime( _currenttime - _starttime )
		if difftime > _checkinterval then
			_starttime = _currenttime
			for handler, timestamp in pairs( _writetimes ) do
				if os_difftime( _currenttime - timestamp ) > _sendtimeout then
					handler.disconnect( )( handler, "send timeout" )
					handler:force_close()	 -- forced disconnect
				end
			end
			for handler, timestamp in pairs( _readtimes ) do
				if os_difftime( _currenttime - timestamp ) > _readtimeout then
					if not(handler.onreadtimeout) or handler:onreadtimeout() ~= true then
						handler.disconnect( )( handler, "read timeout" )
						handler:close( )	-- forced disconnect?
					end
				end
			end
		end

		-- Fire timers
		if _currenttime - _timer >= math_min(next_timer_time, 1) then
			next_timer_time = math_huge;
			for i = 1, _timerlistlen do
				local t = _timerlist[ i ]( _currenttime ) -- fire timers
				if t then next_timer_time = math_min(next_timer_time, t); end
			end
			_timer = _currenttime
		else
			next_timer_time = next_timer_time - (_currenttime - _timer);
		end

		-- wait some time (0 by default)
		socket_sleep( _sleeptime )
	until quitting;
	if once and quitting == "once" then quitting = nil; return; end
	return "quitting"
end

local function step()
	return loop(true);
end

local function get_backend()
	return "select";
end

--// EXPERIMENTAL //--

local wrapclient = function( socket, ip, serverport, listeners, pattern, sslctx )
	local handler, socket, err = wrapconnection( nil, listeners, socket, ip, serverport, "clientport", pattern, sslctx )
	if not handler then return nil, err end
	_socketlist[ socket ] = handler
	if not sslctx then
		_sendlistlen = addsocket(_sendlist, socket, _sendlistlen)
		if listeners.onconnect then
			-- When socket is writeable, call onconnect
			local _sendbuffer = handler.sendbuffer;
			handler.sendbuffer = function ()
				_sendlistlen = removesocket( _sendlist, socket, _sendlistlen );
				handler.sendbuffer = _sendbuffer;
				listeners.onconnect(handler);
				-- If there was data with the incoming packet, handle it now.
				if #handler:bufferqueue() > 0 then
					return _sendbuffer();
				end
			end
		end
	end
	return handler, socket
end

local addclient = function( address, port, listeners, pattern, sslctx )
	local client, err = luasocket.tcp( )
	if err then
		return nil, err
	end
	client:settimeout( 0 )
	_, err = client:connect( address, port )
	if err then -- try again
		local handler = wrapclient( client, address, port, listeners )
	else
		wrapconnection( nil, listeners, client, address, port, "clientport", pattern, sslctx )
	end
end

--// EXPERIMENTAL //--

----------------------------------// BEGIN //--

use "setmetatable" ( _socketlist, { __mode = "k" } )
use "setmetatable" ( _readtimes, { __mode = "k" } )
use "setmetatable" ( _writetimes, { __mode = "k" } )

_timer = luasocket_gettime( )
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

	addclient = addclient,
	wrapclient = wrapclient,
	
	loop = loop,
	link = link,
	step = step,
	stats = stats,
	closeall = closeall,
	addserver = addserver,
	getserver = getserver,
	setlogger = setlogger,
	getsettings = getsettings,
	setquitting = setquitting,
	removeserver = removeserver,
	get_backend = get_backend,
	changesettings = changesettings,
}
