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
local log = require "util.logger".init("server_epoll");
local epoll = require "epoll";
local socket = require "socket";
local luasec = require "ssl";
local gettime = require "util.time".now;
local createtable = require "util.table".create;

local _ENV = nil;

local cfg = {
	read_timeout = 900;
	write_timeout = 7;
	tcp_backlog = 128;
	accept_retry_interval = 10;
};

local fds = createtable(10, 0); -- FD -> conn
local timers = {};

local function noop() end
local function closetimer(t)
	t[1] = 0;
	t[2] = noop;
end

local resort_timers = false;
local function at(time, f)
	local timer = { time, f, close = closetimer };
	t_insert(timers, timer);
	resort_timers = true;
	return timer;
end
local function addtimer(timeout, f)
	return at(gettime() + timeout, f);
end

local function runtimers()
	if resort_timers then
		-- Sort earliest timers to the end
		t_sort(timers, function (a, b) return a[1] > b[1]; end);
		resort_timers = false;
	end

	--[[ Is it worth it to skip the noop calls?
	for i = #timers, 1, -1 do
		if timers[i][2] == noop then
			timers[i] = nil;
		else
			break;
		end
	end
	--]]

	local next_delay = 86400;

	-- Iterate from the end and remove completed timers
	for i = #timers, 1, -1 do
		local timer = timers[i];
		local t, f = timer[1], timer[2];
		local now = gettime(); -- inside or before the loop?
		if t > now then
			local diff = t - now;
			if diff < next_delay then
				next_delay = diff;
			end
			return next_delay;
		end
		local new_timeout = f(now);
		if new_timeout then
			local t_diff = t + new_timeout - now;
			if t_diff < 1e-6 then
				t_diff = 1e-6;
			end
			if t_diff < next_delay then
				next_delay = t_diff;
			end
			timer[1] = t + new_timeout;
			resort_timers = true;
		else
			t_remove(timers, i);
		end
	end
	if next_delay < 1e-6 then
		next_delay = 1e-6;
	end
	return next_delay;
end

local interface = {};
local interface_mt = { __index = interface };

function interface_mt:__tostring()
	if self.peer then
		if self.conn then
			return ("%d %s [%s]:%d"):format(self:getfd(), tostring(self.conn), self.peer[1], self.peer[2]);
		else
			return ("%d [%s]:%d"):format(self:getfd(), self.peer[1], self.peer[2]);
		end
	end
	return tostring(self:getfd());
end

function interface:setlistener(listeners)
	self.listeners = listeners;
end

function interface:getfd()
	return self.conn:getfd();
end

function interface:ip()
	return self.peer[1];
end

function interface:socket()
	return self.conn;
end

function interface:setoption(k, v)
	-- LuaSec doesn't expose setoption :(
	if self.conn.setoption then
		self.conn:setoption(k, v);
	end
end

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
			if self:onreadtimeout() then
				return cfg.read_timeout;
			else
				self.listeners.ondisconnect(self, "read timeout");
				self:destroy();
			end
		end);
	end
end

function interface:onreadtimeout()
	if self.listeners.onreadtimeout then
		return self.listeners.onreadtimeout(self);
	end
end

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
			self.listeners.ondisconnect(self, "write timeout");
			self:destroy();
		end);
	end
end

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

function interface:setflags(r, w)
	if r ~= nil then self._wantread = r; end
	if w ~= nil then self._wantwrite = w; end
	local flags = self:flags();
	local currentflags = self._flags;
	if flags == currentflags then
		return true;
	end
	local fd = self:getfd();
	local op = "mod";
	if not flags then
		op = "del";
	elseif not currentflags then
		op = "add";
	end
	local ok, err = epoll.ctl(op, fd, flags);
	if not ok then return ok, err end
	self._flags = flags;
	return true;
end

function interface:onreadable()
	local data, err, partial = self.conn:receive(self._pattern);
	if data or partial then
		self.listeners.onincoming(self, data or partial, err);
	end
	if err == "wantread" then
		self:setflags(true, nil);
	elseif err == "wantwrite" then
		self:setflags(nil, true);
	elseif err ~= "timeout" then
		self.listeners.ondisconnect(self, err);
		self:destroy()
		return;
	end
	self:setreadtimeout();
end

function interface:onwriteable()
	local buffer = self.writebuffer;
	local data = t_concat(buffer);
	local ok, err, partial = self.conn:send(data);
	if ok then
		for i = #buffer, 1, -1 do
			buffer[i] = nil;
		end
		self:ondrain();
		if not buffer[1] then
			self:setflags(nil, false);
			self:setwritetimeout(false);
		else
			self:setwritetimeout();
		end
	elseif partial then
		buffer[1] = data:sub(partial+1)
		for i = #buffer, 2, -1 do
			buffer[i] = nil;
		end
		self:setwritetimeout();
	end
	if err == "wantwrite" or err == "timeout" then
		self:setflags(nil, true);
	elseif err == "wantread" then
		self:setflags(true, nil);
	elseif err and err ~= "timeout" then
		self.listeners.ondisconnect(self, err);
		self:destroy();
	end
end

function interface:ondrain()
	if self.listeners.ondrain then
		self.listeners.ondrain(self);
	end
	if self._starttls then
		self:starttls();
	elseif self._toclose then
		self:close();
	end
end

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

function interface:close()
	if self._wantwrite then
		self._toclose = true;
	else
		self.close = noop;
		self.listeners.ondisconnect(self);
		self:destroy();
	end
end

function interface:destroy()
	self:setflags(false, false);
	self:setwritetimeout(false);
	self:setreadtimeout(false);
	fds[self:getfd()] = nil;
	return self.conn:close();
end

function interface:ssl()
	return self._tls;
end

function interface:starttls(ctx)
	if ctx then self.tls = ctx; end
	if self.writebuffer and self.writebuffer[1] then
		self._starttls = true;
	else
		self:setflags(false, false);
		local conn, err = luasec.wrap(self.conn, ctx or self.tls);
		if not conn then
			self.listeners.ondisconnect(self, err);
			self:destroy();
		end
		conn:settimeout(0);
		self.conn = conn;
		self._starttls = nil;
		self.onwriteable = interface.tlshandskake;
		self.onreadable = interface.tlshandskake;
		self:setflags(true, true);
	end
end

function interface:tlshandskake()
	local ok, err = self.conn:dohandshake();
	if ok then
		self.onwriteable = nil;
		self.onreadable = nil;
		self:setflags(true, true);
		local old = self._tls;
		self._tls = true;
		self.starttls = false;
		if old == false then
			self:onconnect();
		elseif self.listeners.onstatus then
			self.listeners.onstatus(self, "ssl-handshake-complete");
		end
	elseif err == "wantread" then
		self:setflags(true, false);
		self:setwritetimeout(false);
		self:setreadtimeout(cfg.handshake_timeout);
	elseif err == "wantwrite" then
		self:setflags(false, true);
		self:setreadtimeout(false);
		self:setwritetimeout(cfg.handshake_timeout);
	else
		self.listeners.ondisconnect(self, err);
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
		_pattern = pattern or server._pattern;
		writebuffer = {};
		tls = tls;
	}, interface_mt);
	if client.getpeername then
		conn.peer = {client:getpeername()}
	end

	fds[conn:getfd()] = conn;
	return conn;
end

function interface:onacceptable()
	local conn, err = self.conn:accept();
	if not conn then
		log(debug, "Error accepting new client: %s, server will be paused for %ds", err, cfg.accept_retry_interval);
		self:pausefor(cfg.accept_retry_interval);
		return;
	end
	local client = wrapsocket(conn, self, nil, self.listeners, self.tls);
	if self.tls then
		client._tls = false;
		client:starttls();
	else
		self.listeners.onconnect(client);
		client:setflags(true);
	end
	client:setreadtimeout();
end

function interface:pause()
	self:setflags(false);
end

function interface:resume()
	self:setflags(true);
end

function interface:pausefor(t)
	if self._wantread then
		self:setflags(false);
		addtimer(t, function () self:setflags(true); end);
	end
end

function interface:onconnect()
	self.onreadable = nil;
	self.onwriteable = nil;
	self.listeners.onconnect(self);
end

local function addclient(addr, port, listeners, pattern, tls)
	local conn, err = socket.connect(addr, port);
	if not conn then return conn, err; end
	return wrapsocket(conn, nil, pattern, listeners, tls);
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
		peer = { addr, port };
	}, interface_mt);
	server:setflags(true, false);
	fds[server:getfd()] = server;
	return server;
end

-- COMPAT
local function wrapclient(client, addr, port, listeners, mode, tls)
	local conn = setmetatable({
		conn = client;
		created = gettime();
		listeners = listeners;
		_pattern = mode;
		writebuffer = {};
		tls = tls;
		onreadable = interface.onconnect;
		onwriteable = interface.onconnect;
		peer = { addr, port };
	}, interface_mt);
	fds[conn:getfd()] = conn;
	conn:setflags(true, true);
	return conn;
end

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

local quitting = nil;

local function setquitting()
	quitting = "quitting";
end

local function loop()
	repeat
		local t = runtimers();
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
	until quitting;
	return quitting;
end

return {
	get_backend = function () return "epoll"; end;
	addserver = addserver;
	addclient = addclient;
	add_task = addtimer;
	at = at;
	loop = loop;
	setquitting = setquitting;
	wrapclient = wrapclient;
	link = link;

	-- libevent emulation
	event = { EV_READ = "r", EV_WRITE = "w", EV_READWRITE = "rw", EV_LEAVE = -1 };
	addevent = function (fd, mode, callback)
		local function onevent(self)
			local ret = self:callback();
			if ret == -1 then
				epoll.ctl("del", fd);
			elseif ret then
				epoll.ctl("mod", fd, mode);
			end
		end

		local conn = {
			callback = callback;
			onreadable = onevent;
			onwriteable = onevent;
			close = function ()
				fds[fd] = nil;
				return epoll.ctl("del", fd);
			end;
		};
		fds[fd] = conn;
		local ok, err = epoll.ctl("add", fd, mode or "r");
		if not ok then return ok, err; end
		return conn;
	end;
};
