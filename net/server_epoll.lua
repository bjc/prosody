-- Prosody IM
-- Copyright (C) 2016 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

-- server_epoll
--  Server backend based on https://luarocks.org/modules/zash/lua-epoll

local t_sort = table.sort;
local t_insert = table.insert;
local t_remove = table.remove;
local t_concat = table.concat;
local setmetatable = setmetatable;
local tostring = tostring;
local pcall = pcall;
local next = next;
local pairs = pairs;
local log = require "util.logger".init("server_epoll");
local epoll = require "epoll";
local socket = require "socket";
local luasec = require "ssl";
local gettime = require "util.time".now;
local createtable = require "util.table".create;
local _SOCKETINVALID = socket._SOCKETINVALID or -1;

assert(socket.tcp6 and socket.tcp4, "Incompatible LuaSocket version");

local _ENV = nil;

local default_config = { __index = {
	read_timeout = 900;
	write_timeout = 7;
	tcp_backlog = 128;
	accept_retry_interval = 10;
	read_retry_delay = 1e-06;
	connect_timeout = 20;
	handshake_timeout = 60;
	max_wait = 86400;
	min_wait = 1e-06;
}};
local cfg = default_config.__index;

local fds = createtable(10, 0); -- FD -> conn

-- Timer and scheduling --

local timers = {};

local function noop() end
local function closetimer(t)
	t[1] = 0;
	t[2] = noop;
end

-- Set to true when timers have changed
local resort_timers = false;

-- Add absolute timer
local function at(time, f)
	local timer = { time, f, close = closetimer };
	t_insert(timers, timer);
	resort_timers = true;
	return timer;
end

-- Add relative timer
local function addtimer(timeout, f)
	return at(gettime() + timeout, f);
end

-- Run callbacks of expired timers
-- Return time until next timeout
local function runtimers(next_delay, min_wait)
	-- Any timers at all?
	if not timers[1] then
		return next_delay;
	end

	if resort_timers then
		-- Sort earliest timers to the end
		t_sort(timers, function (a, b) return a[1] > b[1]; end);
		resort_timers = false;
	end

	-- Iterate from the end and remove completed timers
	for i = #timers, 1, -1 do
		local timer = timers[i];
		local t, f = timer[1], timer[2];
		-- Get time for every iteration to increase accuracy
		local now = gettime();
		if t > now then
			-- This timer should not fire yet
			local diff = t - now;
			if diff < next_delay then
				next_delay = diff;
			end
			break;
		end
		local new_timeout = f(now);
		if new_timeout then
			-- Schedule for 'delay' from the time actually scheduled,
			-- not from now, in order to prevent timer drift.
			timer[1] = t + new_timeout;
			resort_timers = true;
		else
			t_remove(timers, i);
		end
	end

	if resort_timers or next_delay < min_wait then
		-- Timers may be added from within a timer callback.
		-- Those would not be considered for next_delay,
		-- and we might sleep for too long, so instead
		-- we return a shorter timeout so we can
		-- properly sort all new timers.
		next_delay = min_wait;
	end

	return next_delay;
end

-- Socket handler interface

local interface = {};
local interface_mt = { __index = interface };

function interface_mt:__tostring()
	if self.sockname and self.peername then
		return ("FD %d (%s, %d, %s, %d)"):format(self:getfd(), self.peername, self.peerport, self.sockname, self.sockport);
	elseif self.sockname or self.peername then
		return ("FD %d (%s, %d)"):format(self:getfd(), self.sockname or self.peername, self.sockport or self.peerport);
	end
	return ("%s FD %d"):format(tostring(self.conn), self:getfd());
end

-- Replace the listener and tell the old one
function interface:setlistener(listeners)
	self:on("detach");
	self.listeners = listeners;
end

-- Call a listener callback
function interface:on(what, ...)
	if not self.listeners then
		log("error", "%s has no listeners", self);
		return;
	end
	local listener = self.listeners["on"..what];
	if not listener then
		-- log("debug", "Missing listener 'on%s'", what); -- uncomment for development and debugging
		return;
	end
	local ok, err = pcall(listener, self, ...);
	if not ok then
		log("error", "Error calling on%s: %s", what, err);
	end
	return err;
end

-- Return the file descriptor number
function interface:getfd()
	if self.conn then
		return self.conn:getfd();
	end
	return _SOCKETINVALID;
end

-- Get IP address
function interface:ip()
	return self.peername or self.sockname;
end

-- Get a port number, doesn't matter which
function interface:port()
	return self.sockport or self.peerport;
end

-- Get local port number
function interface:clientport()
	return self.sockport;
end

-- Get remote port
function interface:serverport()
	if self.sockport then
		return self.sockport;
	elseif self.server then
		self.server:port();
	end
end

-- Return underlying socket
function interface:socket()
	return self.conn;
end

function interface:set_mode(new_mode)
	self._pattern = new_mode;
end

function interface:setoption(k, v)
	-- LuaSec doesn't expose setoption :(
	if self.conn.setoption then
		self.conn:setoption(k, v);
	end
end

-- Timeout for detecting dead or idle sockets
function interface:setreadtimeout(t)
	if t == false then
		if self._readtimeout then
			self._readtimeout:close();
			self._readtimeout = nil;
		end
		return
	end
	t = t or cfg.read_timeout;
	if self._readtimeout then
		self._readtimeout[1] = gettime() + t;
		resort_timers = true;
	else
		self._readtimeout = addtimer(t, function ()
			if self:on("readtimeout") then
				return cfg.read_timeout;
			else
				self:on("disconnect", "read timeout");
				self:destroy();
			end
		end);
	end
end

-- Timeout for detecting dead sockets
function interface:setwritetimeout(t)
	if t == false then
		if self._writetimeout then
			self._writetimeout:close();
			self._writetimeout = nil;
		end
		return
	end
	t = t or cfg.write_timeout;
	if self._writetimeout then
		self._writetimeout[1] = gettime() + t;
		resort_timers = true;
	else
		self._writetimeout = addtimer(t, function ()
			self:on("disconnect", "write timeout");
			self:destroy();
		end);
	end
end

-- lua-epoll flag for currently requested poll state
function interface:flags()
	if self._wantread then
		if self._wantwrite then
			return "rw";
		end
		return "r";
	elseif self._wantwrite then
		return "w";
	end
end

-- Add or remove sockets or modify epoll flags
function interface:setflags(r, w)
	if r ~= nil then self._wantread = r; end
	if w ~= nil then self._wantwrite = w; end
	local flags = self:flags();
	local currentflags = self._flags;
	if flags == currentflags then
		return true;
	end
	local fd = self:getfd();
	if fd < 0 then
		self._wantread, self._wantwrite = nil, nil;
		return nil, "invalid fd";
	end
	local op = "mod";
	if not flags then
		op = "del";
	elseif not currentflags then
		op = "add";
	end
	local ok, err = epoll.ctl(op, fd, flags);
--	log("debug", "epoll_ctl(%q, %d, %q) -> %s" .. (err and ", %q" or ""),
--		op, fd, flags or "", tostring(ok), err);
	if not ok then return ok, err end
	if op == "add" then
		fds[fd] = self;
	elseif op == "del" then
		fds[fd] = nil;
	end
	self._flags = flags;
	return true;
end

-- Called when socket is readable
function interface:onreadable()
	local data, err, partial = self.conn:receive(self._pattern);
	if data then
		self:on("incoming", data);
	else
		if partial then
			self:on("incoming", partial, err);
		end
		if err == "wantread" then
			self:setflags(true, nil);
		elseif err == "wantwrite" then
			self:setflags(nil, true);
		elseif err ~= "timeout" then
			self:on("disconnect", err);
			self:destroy()
			return;
		end
	end
	if not self.conn then return; end
	if self.conn:dirty() then
		self:setreadtimeout(false);
		self:pausefor(cfg.read_retry_delay);
	else
		self:setreadtimeout();
	end
end

-- Called when socket is writable
function interface:onwriteable()
	local buffer = self.writebuffer;
	local data = t_concat(buffer);
	local ok, err, partial = self.conn:send(data);
	if ok then
		for i = #buffer, 1, -1 do
			buffer[i] = nil;
		end
		self:setflags(nil, false);
		self:setwritetimeout(false);
		self:ondrain(); -- Be aware of writes in ondrain
		return;
	end
	if partial then
		buffer[1] = data:sub(partial+1);
		for i = #buffer, 2, -1 do
			buffer[i] = nil;
		end
		self:setwritetimeout();
	end
	if err == "wantwrite" or err == "timeout" then
		self:setflags(nil, true);
	elseif err == "wantread" then
		self:setflags(true, nil);
	elseif err ~= "timeout" then
		self:on("disconnect", err);
		self:destroy();
	end
end

-- The write buffer has been successfully emptied
function interface:ondrain()
	if self._toclose then
		return self:close();
	elseif self._starttls then
		return self:starttls();
	else
		return self:on("drain");
	end
end

-- Add data to write buffer and set flag for wanting to write
function interface:write(data)
	local buffer = self.writebuffer;
	if buffer then
		t_insert(buffer, data);
	else
		self.writebuffer = { data };
	end
	self:setwritetimeout();
	self:setflags(nil, true);
	return #data;
end
interface.send = interface.write;

-- Close, possibly after writing is done
function interface:close()
	if self._wantwrite then
		self:setflags(false, true); -- Flush final buffer contents
		self.write, self.send = noop, noop; -- No more writing
		log("debug", "Close %s after writing", tostring(self));
		self._toclose = true;
	else
		log("debug", "Close %s now", tostring(self));
		self.write, self.send = noop, noop;
		self.close = noop;
		self:on("disconnect");
		self:destroy();
	end
end

function interface:destroy()
	self:setflags(false, false);
	self:setwritetimeout(false);
	self:setreadtimeout(false);
	self.onreadable = noop;
	self.onwriteable = noop;
	self.destroy = noop;
	self.close = noop;
	self.on = noop;
	self.conn:close();
	self.conn = nil;
end

function interface:ssl()
	return self._tls;
end

function interface:starttls(ctx)
	if ctx then self.tls = ctx; end
	if self.writebuffer and self.writebuffer[1] then
		log("debug", "Start TLS on %s after write", tostring(self));
		self._starttls = true;
		self:setflags(nil, true); -- make sure wantwrite is set
	else
		log("debug", "Start TLS on %s now", tostring(self));
		self:setflags(false, false);
		local conn, err = luasec.wrap(self.conn, ctx or self.tls);
		if not conn then
			self:on("disconnect", err);
			self:destroy();
			return conn, err;
		end
		conn:settimeout(0);
		self.conn = conn;
		self._starttls = nil;
		self.onwriteable = interface.tlshandskake;
		self.onreadable = interface.tlshandskake;
		self:setflags(true, true);
		self:setwritetimeout(cfg.handshake_timeout);
	end
end

function interface:tlshandskake()
	self:setwritetimeout(false);
	self:setreadtimeout(false);
	local ok, err = self.conn:dohandshake();
	if ok then
		log("debug", "TLS handshake on %s complete", tostring(self));
		self.onwriteable = nil;
		self.onreadable = nil;
		self:setflags(true, true);
		local old = self._tls;
		self._tls = true;
		self.starttls = false;
		if old == false then
			self:init();
		else
			self:setflags(true, true);
			self:on("status", "ssl-handshake-complete");
		end
	elseif err == "wantread" then
		log("debug", "TLS handshake on %s to wait until readable", tostring(self));
		self:setflags(true, false);
		self:setreadtimeout(cfg.handshake_timeout);
	elseif err == "wantwrite" then
		log("debug", "TLS handshake on %s to wait until writable", tostring(self));
		self:setflags(false, true);
		self:setwritetimeout(cfg.handshake_timeout);
	else
		log("debug", "TLS handshake error on %s: %s", tostring(self), err);
		self:on("disconnect", err);
		self:destroy();
	end
end

local function wrapsocket(client, server, pattern, listeners, tls) -- luasocket object -> interface object
	client:settimeout(0);
	local conn = setmetatable({
		conn = client;
		server = server;
		created = gettime();
		listeners = listeners;
		_pattern = pattern or (server and server._pattern);
		writebuffer = {};
		tls = tls;
	}, interface_mt);

	if client.getpeername then
		conn.peername, conn.peerport = client:getpeername();
	end
	if client.getsockname then
		conn.sockname, conn.sockport = client:getsockname();
	end
	return conn;
end

-- A server interface has new incoming connections waiting
-- This replaces the onreadable callback
function interface:onacceptable()
	local conn, err = self.conn:accept();
	if not conn then
		log("debug", "Error accepting new client: %s, server will be paused for %ds", err, cfg.accept_retry_interval);
		self:pausefor(cfg.accept_retry_interval);
		return;
	end
	local client = wrapsocket(conn, self, nil, self.listeners, self.tls);
	log("debug", "New connection %s", tostring(client));
	client:init();
end

-- Initialization
function interface:init()
	if self.tls and not self._tls then
		self._tls = false; -- This means we should call onconnect when TLS is up
		return self:starttls();
	else
		self.onwriteable = interface.onconnect;
		self:setwritetimeout();
		return self:setflags(false, true);
	end
end

function interface:pause()
	return self:setflags(false);
end

function interface:resume()
	return self:setflags(true);
end

-- Pause connection for some time
function interface:pausefor(t)
	if self._pausefor then
		self._pausefor:close();
	end
	if t == false then return; end
	self:setflags(false);
	self._pausefor = addtimer(t, function ()
		self._pausefor = nil;
		if self.conn and self.conn:dirty() then
			self:onreadable();
		end
		self:setflags(true);
	end);
end

-- Connected!
function interface:onconnect()
	self.onwriteable = nil;
	self:on("connect");
	self:setflags(true);
	return self:onwriteable();
end

local function addserver(addr, port, listeners, pattern, tls)
	local conn, err = socket.bind(addr, port, cfg.tcp_backlog);
	if not conn then return conn, err; end
	conn:settimeout(0);
	local server = setmetatable({
		conn = conn;
		created = gettime();
		listeners = listeners;
		_pattern = pattern;
		onreadable = interface.onacceptable;
		tls = tls;
		sockname = addr;
		sockport = port;
	}, interface_mt);
	server:setflags(true, false);
	return server;
end

-- COMPAT
local function wrapclient(conn, addr, port, listeners, pattern, tls)
	local client = wrapsocket(conn, nil, pattern, listeners, tls);
	if not client.peername then
		client.peername, client.peerport = addr, port;
	end
	client:init();
	return client;
end

-- New outgoing TCP connection
local function addclient(addr, port, listeners, pattern, tls)
	local conn, err = socket.tcp();
	if not conn then return conn, err; end
	conn:settimeout(0);
	conn:connect(addr, port);
	local client = wrapsocket(conn, nil, pattern, listeners, tls)
	client:init();
	return client, conn;
end

-- Dump all data from one connection into another
local function link(from, to)
	from.listeners = setmetatable({
		onincoming = function (_, data)
			from:pause();
			to:write(data);
		end,
	}, {__index=from.listeners});
	to.listeners = setmetatable({
		ondrain = function ()
			from:resume();
		end,
	}, {__index=to.listeners});
	from:setflags(true, nil);
	to:setflags(nil, true);
end

-- XXX What uses this?
-- net.adns
function interface:set_send(new_send)
	self.send = new_send;
end

-- Close all connections and servers
local function closeall()
	for fd, conn in pairs(fds) do -- luacheck: ignore 213/fd
		conn:close();
	end
end

local quitting = nil;

-- Signal main loop about shutdown via above upvalue
local function setquitting(quit)
	if quit then
		quitting = "quitting";
		closeall();
	else
		quitting = nil;
	end
end

-- Main loop
local function loop(once)
	repeat
		local t = runtimers(cfg.max_wait, cfg.min_wait);
		local fd, r, w = epoll.wait(t);
		if fd then
			local conn = fds[fd];
			if conn then
				if r then
					conn:onreadable();
				end
				if w then
					conn:onwriteable();
				end
			else
				log("debug", "Removing unknown fd %d", fd);
				epoll.ctl("del", fd);
			end
		elseif r ~= "timeout" then
			log("debug", "epoll_wait error: %s", tostring(r));
		end
	until once or (quitting and next(fds) == nil);
	return quitting;
end

return {
	get_backend = function () return "epoll"; end;
	addserver = addserver;
	addclient = addclient;
	add_task = addtimer;
	at = at;
	loop = loop;
	closeall = closeall;
	setquitting = setquitting;
	wrapclient = wrapclient;
	link = link;
	set_config = function (newconfig)
		cfg = setmetatable(newconfig, default_config);
	end;

	-- libevent emulation
	event = { EV_READ = "r", EV_WRITE = "w", EV_READWRITE = "rw", EV_LEAVE = -1 };
	addevent = function (fd, mode, callback)
		local function onevent(self)
			local ret = self:callback();
			if ret == -1 then
				self:setflags(false, false);
			elseif ret then
				self:setflags(mode == "r" or mode == "rw", mode == "w" or mode == "rw");
			end
		end

		local conn = setmetatable({
			getfd = function () return fd; end;
			callback = callback;
			onreadable = onevent;
			onwriteable = onevent;
			close = function (self)
				self:setflags(false, false);
				fds[fd] = nil;
			end;
		}, interface_mt);
		local ok, err = conn:setflags(mode == "r" or mode == "rw", mode == "w" or mode == "rw");
		if not ok then return ok, err; end
		return conn;
	end;
};
