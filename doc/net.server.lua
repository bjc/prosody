-- Prosody IM
-- Copyright (C) 2014,2016 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.

--luacheck: ignore

--[[
This file is a template for writing a net.server compatible backend.
]]

--[[
Read patterns (also called modes) can be one of:
  - "*a": Read as much as possible
  - "*l": Read until end of line
]]

--- Handle API
local handle_mt = {};
local handle_methods = {};
handle_mt.__index = handle_methods;

function handle_methods:set_mode(new_pattern)
end

function handle_methods:setlistener(listeners)
end

function handle_methods:setoption(option, value)
end

function handle_methods:ip()
end

function handle_methods:starttls(sslctx)
end

function handle_methods:write(data)
end

function handle_methods:close()
end

function handle_methods:pause()
end

function handle_methods:resume()
end

--[[
Returns
  - socket: the socket object underlying this handle
]]
function handle_methods:socket()
end

--[[
Returns
  - boolean: if an ssl context has been set on this handle
]]
function handle_methods:ssl()
end


--- Listeners API
local listeners = {}

--[[ connect
Called when a client socket has established a connection with it's peer
]]
function listeners.onconnect(handle)
end

--[[ incoming
Called when data is received
If reading data failed this will be called with `nil, "error message"`
]]
function listeners.onincoming(handle, buff, err)
end

--[[ status
Known statuses:
  - "ssl-handshake-complete"
]]
function listeners.onstatus(handle, status)
end

--[[ disconnect
Called when the peer has closed the connection
]]
function listeners.ondisconnect(handle)
end

--[[ drain
Called when the handle's write buffer is empty
]]
function listeners.ondrain(handle)
end

--[[ readtimeout
Called when a socket inactivity timeout occurs
]]
function listeners.onreadtimeout(handle)
end

--[[ detach: Called when other listeners are going to be removed
Allows for clean-up
]]
function listeners.ondetach(handle)
end

--- Top level functions

--[[ Returns the syscall level event mechanism in use.

Returns:
  - backend: e.g. "select", "epoll"
]]
local function get_backend()
end

--[[ Starts the event loop.

Returns:
  - "quitting"
]]
local function loop()
end

--[[ Stop a running loop()
]]
local function setquitting(quit)
end


--[[ Links to two handles together, so anything written to one is piped to the other

Arguments:
  - sender, receiver: handles to link
  - buffersize: maximum #bytes until sender will be locked
]]
local function link(sender, receiver, buffersize)
end

--[[ Binds and listens on the given address and port
If `sslctx` is given, the connecting clients will have to negotiate an SSL session

Arguments:
  - address: address to bind to, may be "*" to bind all addresses. will be resolved if it is a string.
  - port: port to bind (as number)
  - listeners: a table of listeners
  - pattern: the read pattern
  - sslctx: is a valid luasec constructor

Returns:
  - handle
  - nil, "an error message": on failure (e.g. out of file descriptors)
]]
local function addserver(address, port, listeners, pattern, sslctx)
end

--[[ Binds and listens on the given address and port
Mostly the same as addserver but with all optional arguments in a table

Arguments:
  - address: address to bind to, may be "*" to bind all addresses. will be resolved if it is a string.
  - port: port to bind (as number)
  - listeners: a table of listeners
	- config: table of extra settings
		- read_size: the amount of bytes to read or a read pattern
		- tls_ctx: is a valid luasec constructor
		- tls_direct: boolean true for direct TLS, false (or nil) for starttls

Returns:
  - handle
  - nil, "an error message": on failure (e.g. out of file descriptors)
]]
local function listen(address, port, listeners, config)
end


--[[ Wraps a lua-socket socket client socket in a handle.
The socket must be already connected to the remote end.
If `sslctx` is given, a SSL session will be negotiated before listeners are called.

Arguments:
  - socket: the lua-socket object to wrap
  - ip: returned by `handle:ip()`
  - port:
  - listeners: a table of listeners
  - pattern: the read pattern
  - sslctx: is a valid luasec constructor
  - typ: the socket type, one of:
	  - "tcp"
	  - "tcp6"
	  - "udp"

Returns:
  - handle, socket
  - nil, "an error message": on failure (e.g. )
]]
local function wrapclient(socket, ip, serverport, listeners, pattern, sslctx)
end

--[[ Connects to the given address and port
If `sslctx` is given, a SSL session will be negotiated before listeners are called.

Arguments:
  - address: address to connect to. will be resolved if it is a string.
  - port: port to connect to (as number)
  - listeners: a table of listeners
  - pattern: the read pattern
  - sslctx: is a valid luasec constructor
  - typ: the socket type, one of:
	  - "tcp"
	  - "tcp6"
	  - "udp"

Returns:
  - handle
  - nil, "an error message": on failure (e.g. out of file descriptors)
]]
local function addclient(address, port, listeners, pattern, sslctx, typ)
end

--[[ Close all handles
]]
local function closeall()
end

--[[ The callback should be called after `delay` seconds.
The callback should be called with the time at the point of firing.
If the callback returns a number, it should be called again after that many seconds.

Arguments:
  - delay: number of seconds to wait
  - callback: function to call.
]]
local function add_task(delay, callback)
end

--[[ Adds a handler for when a signal is fired.
Optional to implement
callback does not take any arguments

Arguments:
  - signal_id: the signal id (as number) to listen for
  - handler: callback
]]
local function hook_signal(signal_id, handler)
end

--[[ Adds a low-level FD watcher
Arguments:
-   fd_number: A non-negative integer representing a file descriptor or
    object with a :getfd() method returning one
-   on_readable: Optional callback for when the FD is readable
-   on_writable: Optional callback for when the FD is writable

Returns:
-   net.server handle
]]
local function watchfd(fd_number, on_readable, on_writable)
end

return {
	get_backend = get_backend;
	loop = loop;
	setquitting = setquitting;
	link = link;
	addserver = addserver;
	wrapclient = wrapclient;
	addclient = addclient;
	closeall = closeall;
	hook_signal = hook_signal;
	watchfd = watchfd;
	listen = listen;
}
