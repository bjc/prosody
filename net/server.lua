--[[

		server.lua by blastbeat of the luadch project
		
		re-used here under the MIT/X Consortium License

		- this script contains the server loop of the program
		- other scripts can reg a server here

]]--

----------------------------------// DECLARATION //--

--// constants //--

local STAT_UNIT = 1 / ( 1024 * 1024 )    -- mb

--// lua functions //--

local function use( what ) return _G[ what ] end

local type = use "type"
local pairs = use "pairs"
local ipairs = use "ipairs"
local tostring = use "tostring"
local collectgarbage = use "collectgarbage"

--// lua libs //--

local table = use "table"
local coroutine = use "coroutine"

--// lua lib methods //--

local table_concat = table.concat
local table_remove = table.remove
local string_sub = use'string'.sub
local coroutine_wrap = coroutine.wrap
local coroutine_yield = coroutine.yield
local print = print;
local out_put = function () end --print;
local out_error = print;

--// extern libs //--

local luasec = select(2, pcall(require, "ssl"))
local luasocket = require "socket"

--// extern lib methods //--

local ssl_wrap = ( luasec and luasec.wrap )
local socket_bind = luasocket.bind
local socket_select = luasocket.select
local ssl_newcontext = ( luasec and luasec.newcontext )

--// functions //--

local loop
local stats
local addtimer
local closeall
local addserver
local firetimer
local closesocket
local removesocket
local wrapserver
local wraptcpclient
local wrapsslclient

--// tables //--

local listener
local readlist
local writelist
local socketlist
local timelistener

--// simple data types //--

local _
local readlen = 0    -- length of readlist
local writelen = 0    -- lenght of writelist

local sendstat= 0
local receivestat = 0

----------------------------------// DEFINITION //--

listener = { }    -- key = port, value = table
readlist = { }    -- array with sockets to read from
writelist = { }    -- arrary with sockets to write to
socketlist = { }    -- key = socket, value = wrapped socket
timelistener = { }

stats = function( )
	return receivestat, sendstat
end

wrapserver = function( listener, socket, ip, serverport, mode, sslctx )    -- this function wraps a server

	local dispatch, disconnect = listener.listener, listener.disconnect    -- dangerous

	local wrapclient, err

	if sslctx then
		if not ssl_newcontext then
			return nil, "luasec not found"
		end
		if type( sslctx ) ~= "table" then
			out_error "server.lua: wrong server sslctx"
			return nil, "wrong server sslctx"
		end
		sslctx, err = ssl_newcontext( sslctx )
		if not sslctx then
			err = err or "wrong sslctx parameters"
			out_error( "server.lua: ", err )
			return nil, err
		end
		wrapclient = wrapsslclient
		wrapclient = wraptlsclient
	else
		wrapclient = wraptcpclient
	end

	local accept = socket.accept
	local close = socket.close

	--// public methods of the object //--    

	local handler = { }

	handler.shutdown = function( ) end

	--[[handler.listener = function( data, err )
		return ondata( handler, data, err )
	end]]
	handler.ssl = function( )
		return sslctx and true or false
	end
	handler.close = function( closed )
		_ = not closed and close( socket )
		writelen = removesocket( writelist, socket, writelen )
		readlen = removesocket( readlist, socket, readlen )
		socketlist[ socket ] = nil
		handler = nil
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
	handler.receivedata = function( )
		local client, err = accept( socket )    -- try to accept
		if client then
			local ip, clientport = client:getpeername( )
			client:settimeout( 0 )
			local handler, client, err = wrapclient( listener, client, ip, serverport, clientport, mode, sslctx )    -- wrap new client socket
			if err then    -- error while wrapping ssl socket
				return false
			end
			out_put( "server.lua: accepted new client connection from ", ip, ":", clientport )
			return dispatch( handler )
		elseif err then    -- maybe timeout or something else
			out_put( "server.lua: error with new client connection: ", err )
			return false
		end
	end
	return handler
end

wrapsslclient = function( listener, socket, ip, serverport, clientport, mode, sslctx )    -- this function wraps a ssl cleint

	local dispatch, disconnect = listener.listener, listener.disconnect

	--// transform socket to ssl object //--

	local err
	socket, err = ssl_wrap( socket, sslctx )    -- wrap socket
	if err then
		out_put( "server.lua: ssl error: ", err )
		return nil, nil, err    -- fatal error
	end
	socket:settimeout( 0 )

	--// private closures of the object //--

	local writequeue = { }    -- buffer for messages to send

	local eol, fatal_send_error   -- end of buffer

	local sstat, rstat = 0, 0

	--// local import of socket methods //--

	local send = socket.send
	local receive = socket.receive
	local close = socket.close
	--local shutdown = socket.shutdown

	--// public methods of the object //--

	local handler = { }

	handler.getstats = function( )
		return rstat, sstat
	end

	handler.listener = function( data, err )
		return listener( handler, data, err )
	end
	handler.ssl = function( )
		return true
	end
	handler.send = function( _, data, i, j )
			return send( socket, data, i, j )
	end
	handler.receive = function( pattern, prefix )
			return receive( socket, pattern, prefix )
	end
	handler.shutdown = function( pattern )
		--return shutdown( socket, pattern )
	end
	handler.close = function( closed )
		if eol and not fatal_send_error then handler._dispatchdata(); end
		close( socket )
		writelen = ( eol and removesocket( writelist, socket, writelen ) ) or writelen
		readlen = removesocket( readlist, socket, readlen )
		socketlist[ socket ] = nil
		out_put "server.lua: closed handler and removed socket from list"
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

	handler.write = function( data )
		if not eol then
			writelen = writelen + 1
			writelist[ writelen ] = socket
			eol = 0
		end
		eol = eol + 1
		writequeue[ eol ] = data
	end
	handler.writequeue = function( )
		return writequeue
	end
	handler.socket = function( )
		return socket
	end
	handler.mode = function( )
		return mode
	end
	handler._receivedata = function( )
		local data, err, part = receive( socket, mode )    -- receive data in "mode"
		if not err or ( err == "timeout" or err == "wantread" ) then    -- received something
			local data = data or part or ""
			local count = #data * STAT_UNIT
			rstat = rstat + count
			receivestat = receivestat + count
			out_put( "server.lua: read data '", data, "', error: ", err )
			return dispatch( handler, data, err )
		else    -- connections was closed or fatal error
			out_put( "server.lua: client ", ip, ":", clientport, " error: ", err )
			handler.close( )
			disconnect( handler, err )
			writequeue = nil
			handler = nil
			return false
		end
	end
	handler._dispatchdata = function( )    -- this function writes data to handlers
		local buffer = table_concat( writequeue, "", 1, eol )
		local succ, err, byte = send( socket, buffer )
		local count = ( succ or 0 ) * STAT_UNIT
		sstat = sstat + count
		sendstat = sendstat + count
		out_put( "server.lua: sended '", buffer, "', bytes: ", succ, ", error: ", err, ", part: ", byte, ", to: ", ip, ":", clientport )
		if succ then    -- sending succesful
			--writequeue = { }
			eol = nil
			writelen = removesocket( writelist, socket, writelen )    -- delete socket from writelist
			return true
		elseif byte and ( err == "timeout" or err == "wantwrite" ) then    -- want write
			buffer = string_sub( buffer, byte + 1, -1 )    -- new buffer
			writequeue[ 1 ] = buffer    -- insert new buffer in queue
			eol = 1
			return true
		else    -- connection was closed during sending or fatal error
			fatal_send_error = true;
			out_put( "server.lua: client ", ip, ":", clientport, " error: ", err )
			handler.close( )
			disconnect( handler, err )
			writequeue = nil
			handler = nil
			return false
		end
	end

	-- // COMPAT // --

	handler.getIp = handler.ip
	handler.getPort = handler.clientport

	--// handshake //--

	local wrote

	handler.handshake = coroutine_wrap( function( client )
			local err
			for i = 1, 10 do    -- 10 handshake attemps
				_, err = client:dohandshake( )
				if not err then
					out_put( "server.lua: ssl handshake done" )
					writelen = ( wrote and removesocket( writelist, socket, writelen ) ) or writelen
					handler.receivedata = handler._receivedata    -- when handshake is done, replace the handshake function with regular functions
					handler.dispatchdata = handler._dispatchdata
					return dispatch( handler )
				else
					out_put( "server.lua: error during ssl handshake: ", err )
					if err == "wantwrite" then
						if wrote == nil then
							writelen = writelen + 1
							writelist[ writelen ] = client
							wrote = true
						end
					end
					coroutine_yield( handler, nil, err )    -- handshake not finished
				end
			end
			_ = err ~= "closed" and close( socket )
			handler.close( )
			disconnect( handler, err )
			writequeue = nil
			handler = nil
			return false    -- handshake failed
		end
	)
	handler.receivedata = handler.handshake
	handler.dispatchdata = handler.handshake

	handler.handshake( socket )    -- do handshake

	socketlist[ socket ] = handler
	readlen = readlen + 1
	readlist[ readlen ] = socket

	return handler, socket
end

wraptlsclient = function( listener, socket, ip, serverport, clientport, mode, sslctx )    -- this function wraps a tls cleint

	local dispatch, disconnect = listener.listener, listener.disconnect

	--// transform socket to ssl object //--

	local err

	socket:settimeout( 0 )
	out_put("setting linger on "..tostring(socket))
	socket:setoption("linger", { on = true, timeout = 10 });
	--// private closures of the object //--

	local writequeue = { }    -- buffer for messages to send

	local eol, fatal_send_error   -- end of buffer

	local sstat, rstat = 0, 0

	--// local import of socket methods //--

	local send = socket.send
	local receive = socket.receive
	local close = socket.close
	--local shutdown = socket.shutdown

	--// public methods of the object //--

	local handler = { }

	handler.getstats = function( )
		return rstat, sstat
	end

	handler.listener = function( data, err )
		return listener( handler, data, err )
	end
	handler.ssl = function( )
		return false
	end
	handler.send = function( _, data, i, j )
			return send( socket, data, i, j )
	end
	handler.receive = function( pattern, prefix )
			return receive( socket, pattern, prefix )
	end
	handler.shutdown = function( pattern )
		--return shutdown( socket, pattern )
	end
	handler.close = function( closed )
		if eol and not fatal_send_error then handler._dispatchdata(); end
		close( socket )
		writelen = ( eol and removesocket( writelist, socket, writelen ) ) or writelen
		readlen = removesocket( readlist, socket, readlen )
		socketlist[ socket ] = nil
		out_put "server.lua: closed handler and removed socket from list"
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

	handler.write = function( data )
		if not eol then
			writelen = writelen + 1
			writelist[ writelen ] = socket
			eol = 0
		end
		eol = eol + 1
		writequeue[ eol ] = data
	end
	handler.writequeue = function( )
		return writequeue
	end
	handler.socket = function( )
		return socket
	end
	handler.mode = function( )
		return mode
	end
	handler._receivedata = function( )
		local data, err, part = receive( socket, mode )    -- receive data in "mode"
		if not err or ( err == "timeout" or err == "wantread" ) then    -- received something
			local data = data or part or ""
			local count = #data * STAT_UNIT
			rstat = rstat + count
			receivestat = receivestat + count
			--out_put( "server.lua: read data '", data, "', error: ", err )
			return dispatch( handler, data, err )
		else    -- connections was closed or fatal error
			out_put( "server.lua: client ", ip, ":", clientport, " error: ", err )
			handler.close( )
			disconnect( handler, err )
			writequeue = nil
			handler = nil
			return false
		end
	end
	handler._dispatchdata = function( )    -- this function writes data to handlers
		local buffer = table_concat( writequeue, "", 1, eol )
		local succ, err, byte = send( socket, buffer )
		local count = ( succ or 0 ) * STAT_UNIT
		sstat = sstat + count
		sendstat = sendstat + count
		out_put( "server.lua: sended '", buffer, "', bytes: ", succ, ", error: ", err, ", part: ", byte, ", to: ", ip, ":", clientport )
		if succ then    -- sending succesful
			--writequeue = { }
			eol = nil
			writelen = removesocket( writelist, socket, writelen )    -- delete socket from writelist
			if handler.need_tls then
				out_put("server.lua: connection is ready for tls handshake");
				handler.starttls(true);
				if handler.need_tls then
					out_put("server.lua: uh-oh... we still want tls, something must be wrong");
				end
			end
			return true
		elseif byte and ( err == "timeout" or err == "wantwrite" ) then    -- want write
			buffer = string_sub( buffer, byte + 1, -1 )    -- new buffer
			writequeue[ 1 ] = buffer    -- insert new buffer in queue
			eol = 1
			return true
		else    -- connection was closed during sending or fatal error
			fatal_send_error = true; -- :(
			out_put( "server.lua: client ", ip, ":", clientport, " error: ", err )
			handler.close( )
			disconnect( handler, err )
			writequeue = nil
			handler = nil
			return false
		end
	end

	handler.receivedata, handler.dispatchdata = handler._receivedata, handler._dispatchdata;
	-- // COMPAT // --

	handler.getIp = handler.ip
	handler.getPort = handler.clientport

	--// handshake //--

	local wrote, read
	
	handler.starttls = function (now)
		if not now then out_put("server.lua: we need to do tls, but delaying until later"); handler.need_tls = true; return; end
		out_put( "server.lua: attempting to start tls on "..tostring(socket) )
		socket, err = ssl_wrap( socket, sslctx )    -- wrap socket
		out_put("sslwrapped socket is "..tostring(socket));
		if err then
			out_put( "server.lua: ssl error: ", err )
			return nil, nil, err    -- fatal error
		end
		socket:settimeout( 1 )
		send = socket.send
		receive = socket.receive
		close = socket.close
		handler.ssl = function( )
			return true
		end
		handler.send = function( _, data, i, j )
			return send( socket, data, i, j )
		end
		handler.receive = function( pattern, prefix )
			return receive( socket, pattern, prefix )
		end
		
		handler.starttls = nil;
		
			handler.handshake = coroutine_wrap( function( client )
					local err
					for i = 1, 10 do    -- 10 handshake attemps
						_, err = client:dohandshake( )
						if not err then
							out_put( "server.lua: ssl handshake done" )
							writelen = ( wrote and removesocket( writelist, socket, writelen ) ) or writelen
							handler.receivedata = handler._receivedata    -- when handshake is done, replace the handshake function with regular functions
							handler.dispatchdata = handler._dispatchdata
							handler.need_tls = nil
							socketlist[ client ] = handler
							readlen = readlen + 1
							readlist[ readlen ] = client												
							return true;
						else
							out_put( "server.lua: error during ssl handshake: ", err )
							if err == "wantwrite" then
								if wrote == nil then
									writelen = writelen + 1
									writelist[ writelen ] = client
									wrote = true
								end
							end
							coroutine_yield( handler, nil, err )    -- handshake not finished
						end
					end
					_ = err ~= "closed" and close( socket )
					handler.close( )
					disconnect( handler, err )
					writequeue = nil
					handler = nil
					return false    -- handshake failed
				end
			)
			handler.receivedata = handler.handshake
			handler.dispatchdata = handler.handshake

			handler.handshake( socket )    -- do handshake
		end
	socketlist[ socket ] = handler
	readlen = readlen + 1
	readlist[ readlen ] = socket

	return handler, socket
end

wraptcpclient = function( listener, socket, ip, serverport, clientport, mode )    -- this function wraps a socket

	local dispatch, disconnect = listener.listener, listener.disconnect

	--// private closures of the object //--

	local writequeue = { }    -- list for messages to send

	local eol, fatal_send_error

	local rstat, sstat = 0, 0

	--// local import of socket methods //--

	local send = socket.send
	local receive = socket.receive
	local close = socket.close
	local shutdown = socket.shutdown

	--// public methods of the object //--

	local handler = { }

	handler.getstats = function( )
		return rstat, sstat
	end

	handler.listener = function( data, err )
		return listener( handler, data, err )
	end
	handler.ssl = function( )
		return false
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
	handler.close = function( closed )
		if eol and not fatal_send_error then handler.dispatchdata(); end
		_ = not closed and shutdown( socket )
		_ = not closed and close( socket )
		writelen = ( eol and removesocket( writelist, socket, writelen ) ) or writelen
		readlen = removesocket( readlist, socket, readlen )
		socketlist[ socket ] = nil
		out_put "server.lua: closed handler and removed socket from list"
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
	handler.write = function( data )
		if not eol then
			writelen = writelen + 1
			writelist[ writelen ] = socket
			eol = 0
		end
		eol = eol + 1
		writequeue[ eol ] = data
	end
	handler.writequeue = function( )
		return writequeue
	end
	handler.socket = function( )
		return socket
	end
	handler.mode = function( )
		return mode
	end
	
	handler.receivedata = function( )
		local data, err, part = receive( socket, mode )    -- receive data in "mode"
		if not err or ( err == "timeout" or err == "wantread" ) then    -- received something
			local data = data or part or ""
			local count = #data * STAT_UNIT
			rstat = rstat + count
			receivestat = receivestat + count
			out_put( "server.lua: read data '", data, "', error: ", err )
			return dispatch( handler, data, err )
		else    -- connections was closed or fatal error
			out_put( "server.lua: client ", ip, ":", clientport, " error: ", err )
			handler.close( )
			disconnect( handler, err )
			writequeue = nil
			handler = nil
			return false
		end
	end
	
	handler.dispatchdata = function( )    -- this function writes data to handlers
		local buffer = table_concat( writequeue, "", 1, eol )
		local succ, err, byte = send( socket, buffer )
		local count = ( succ or 0 ) * STAT_UNIT
		sstat = sstat + count
		sendstat = sendstat + count
		out_put( "server.lua: sended '", buffer, "', bytes: ", succ, ", error: ", err, ", part: ", byte, ", to: ", ip, ":", clientport )
		if succ then    -- sending succesful
			--writequeue = { }
			eol = nil
			writelen = removesocket( writelist, socket, writelen )    -- delete socket from writelist
			return true
		elseif byte and ( err == "timeout" or err == "wantwrite" ) then    -- want write
			buffer = string_sub( buffer, byte + 1, -1 )    -- new buffer
			writequeue[ 1 ] = buffer    -- insert new buffer in queue
			eol = 1
			return true
		else    -- connection was closed during sending or fatal error
			fatal_send_error = true; -- :'-(
			out_put( "server.lua: client ", ip, ":", clientport, " error: ", err )
			handler.close( )
			disconnect( handler, err )
			writequeue = nil
			handler = nil
			return false
		end
	end

	-- // COMPAT // --

	handler.getIp = handler.ip
	handler.getPort = handler.clientport

	socketlist[ socket ] = handler
	readlen = readlen + 1
	readlist[ readlen ] = socket

	return handler, socket
end

addtimer = function( listener )
	timelistener[ #timelistener + 1 ] = listener
end

firetimer = function( listener )
	for i, listener in ipairs( timelistener ) do
		listener( )
	end
end

addserver = function( listeners, port, addr, mode, sslctx )    -- this function provides a way for other scripts to reg a server
	local err
	if type( listeners ) ~= "table" then
		err = "invalid listener table"
	else
		for name, func in pairs( listeners ) do
			if type( func ) ~= "function" then
				--err = "invalid listener function"
				break
			end
		end
	end
	if not type( port ) == "number" or not ( port >= 0 and port <= 65535 ) then
		err = "invalid port"
	elseif listener[ port ] then
		err=  "listeners on port '" .. port .. "' already exist"
	elseif sslctx and not luasec then
		err = "luasec not found"
	end
	if err then
		out_error( "server.lua: ", err )
		return nil, err
	end
	addr = addr or "*"
	local server, err = socket_bind( addr, port )
	if err then
		out_error( "server.lua: ", err )
		return nil, err
	end
	local handler, err = wrapserver( listeners, server, addr, port, mode, sslctx )    -- wrap new server socket
	if not handler then
		server:close( )
		return nil, err
	end
	server:settimeout( 0 )
	readlen = readlen + 1
	readlist[ readlen ] = server
	listener[ port ] = listeners
	socketlist[ server ] = handler
	out_put( "server.lua: new server listener on ", addr, ":", port )
	return true
end

removesocket = function( tbl, socket, len )    -- this function removes sockets from a list
	for i, target in ipairs( tbl ) do
		if target == socket then
			len = len - 1
			table_remove( tbl, i )
			return len
		end
	end
	return len
end

closeall = function( )
	for sock, handler in pairs( socketlist ) do
		handler.shutdown( )
		handler.close( )
		socketlist[ sock ] = nil
	end
	writelist, readlist, socketlist = { }, { }, { }
end

closesocket = function( socket )
	writelen = removesocket( writelist, socket, writelen )
	readlen = removesocket( readlist, socket, readlen )
	socketlist[ socket ] = nil
	socket:close( )
end

loop = function( )    -- this is the main loop of the program
	--signal_set( "hub", "run" )
	repeat
		--[[print(readlen, writelen)
		for _, s in ipairs(readlist) do print("R:", tostring(s)) end
		for _, s in ipairs(writelist) do print("W:", tostring(s)) end
		out_put("select()"..os.time())]]
		local read, write, err = socket_select( readlist, writelist, 1 )    -- 1 sec timeout, nice for timers
		for i, socket in ipairs( write ) do    -- send data waiting in writequeues
			local handler = socketlist[ socket ]
			if handler then
				handler.dispatchdata( )
			else
				closesocket( socket )
				out_put "server.lua: found no handler and closed socket (writelist)"    -- this should not happen
			end
		end
		for i, socket in ipairs( read ) do    -- receive data
			local handler = socketlist[ socket ]
			if handler then
				handler.receivedata( )
			else
				closesocket( socket )
				out_put "server.lua: found no handler and closed socket (readlist)"    -- this can happen
			end
		end
		firetimer( )
	until false
	return
end

----------------------------------// BEGIN //--

----------------------------------// PUBLIC INTERFACE //--

return {

	add = addserver,
	loop = loop,
	stats = stats,
	closeall = closeall,
	addtimer = addtimer,
	wraptlsclient = wraptlsclient,
}
