-- libunbound based net.adns replacement for Prosody IM
-- Copyright (C) 2013-2015 Kim Alvefur
--
-- This file is MIT licensed.
--
-- luacheck: ignore prosody

local setmetatable = setmetatable;
local tostring = tostring;
local t_concat = table.concat;
local s_format = string.format;
local s_lower = string.lower;
local s_upper = string.upper;
local noop = function() end;

local logger = require "prosody.util.logger";
local log = logger.init("unbound");
local net_server = require "prosody.net.server";
local libunbound = require"lunbound";
local promise = require"prosody.util.promise";
local new_id = require "prosody.util.id".short;

local dns_utils = require"prosody.util.dns";
local classes, types, errors = dns_utils.classes, dns_utils.types, dns_utils.errors;
local parsers = dns_utils.parsers;

local builtin_defaults = { hoststxt = false }

local function add_defaults(conf)
	conf = conf or {};
	for option, default in pairs(builtin_defaults) do
		if conf[option] == nil then
			conf[option] = default;
		end
	end
	for option, default in pairs(libunbound.config) do
		if conf[option] == nil then
			conf[option] = default;
		end
	end
	return conf;
end

local unbound_config;
if prosody then
	local config = require"prosody.core.configmanager";
	unbound_config = add_defaults(config.get("*", "unbound"));
	prosody.events.add_handler("config-reloaded", function()
		unbound_config = add_defaults(config.get("*", "unbound"));
	end);
end
-- Note: libunbound will default to using root hints if resolvconf is unset

local function connect_server(unbound, server)
	log("debug", "Setting up net.server event handling for %s", unbound);
	return server.watchfd(unbound, function ()
		log("debug", "Processing queries for %s", unbound);
		unbound:process()
	end);
end

local unbound, server_conn;

local function initialize()
	unbound = libunbound.new(unbound_config);
	server_conn = connect_server(unbound, net_server);
end
if prosody then
	prosody.events.add_handler("server-started", initialize);
end

local answer_mt = {
	__tostring = function(self)
		if self._string then return self._string end
		local h = s_format("Status: %s", errors[self.status]);
		if self.secure then
			h = h .. ", Secure";
		elseif self.bogus then
			h = h .. s_format(", Bogus: %s", self.bogus);
		end
		local t = { h };
		local qname = self.canonname or self.qname;
		if self.canonname then
			table.insert(t, self.qname .. "\t" .. classes[self.qclass] .. "\tCNAME\t" .. self.canonname);
		end
		for i = 1, #self do
			table.insert(t, qname .. "\t" .. classes[self.qclass] .. "\t" .. types[self.qtype] .. "\t" .. tostring(self[i]));
		end
		local _string = t_concat(t, "\n");
		self._string = _string;
		return _string;
	end;
};

local waiting_queries = {};

local function prep_answer(a)
	if not a then return end
	local status = errors[a.rcode];
	local qclass = classes[a.qclass];
	local qtype = types[a.qtype];
	a.status, a.class, a.type = status, qclass, qtype;

	local t = s_lower(qtype);
	local rr_mt = { __index = a, __tostring = function(self) return tostring(self[t]) end };
	local parser = parsers[qtype];
	for i = 1, #a do
		if a.bogus then
			-- Discard bogus data
			a[i] = nil;
		else
			a[i] = setmetatable({[t] = parser(a[i])}, rr_mt);
		end
	end
	return setmetatable(a, answer_mt);
end

local function measure(_qclass, _qtype)
	return measure;
end

local function lookup(callback, qname, qtype, qclass)
	if not unbound then initialize(); end
	qtype = qtype and s_upper(qtype) or "A";
	qclass = qclass and s_upper(qclass) or "IN";
	local ntype, nclass = types[qtype], classes[qclass];

	local m;
	local ret;
	local log_query = logger.init("unbound.query"..new_id());
	local function callback_wrapper(a, err)
		m();
		waiting_queries[ret] = nil;
		if a then
			prep_answer(a);
			log_query("debug", "Results for %s %s %s: %s (%s)", qname, qclass, qtype, a.rcode == 0 and (#a .. " items") or a.status,
				a.secure and "Secure" or a.bogus or "Insecure"); -- Insecure as in unsigned
		else
			log_query("error", "Results for %s %s %s: %s", qname, qclass, qtype, tostring(err));
		end
		local ok, cerr = pcall(callback, a, err);
		if not ok then log_query("error", "Error in callback: %s", cerr); end
	end
	log_query("debug", "Resolve %s %s %s", qname, qclass, qtype);
	m = measure(qclass, qtype);
	local err;
	ret, err = unbound:resolve_async(callback_wrapper, qname, ntype, nclass);
	if ret then
		waiting_queries[ret] = callback;
	else
		log_query("error", "Resolver error: %s", err);
	end
	return ret, err;
end

local function lookup_sync(qname, qtype, qclass)
	if not unbound then initialize(); end
	qtype = qtype and s_upper(qtype) or "A";
	qclass = qclass and s_upper(qclass) or "IN";
	local ntype, nclass = types[qtype], classes[qclass];
	local a, err = unbound:resolve(qname, ntype, nclass);
	if not a then return a, err; end
	return prep_answer(a);
end

local function cancel(id)
	local cb = waiting_queries[id];
	unbound:cancel(id);
	if cb then
		cb(nil, "canceled");
		waiting_queries[id] = nil;
	end
	return true;
end

-- Reinitiate libunbound context, drops cache
local function purge()
	for id in pairs(waiting_queries) do cancel(id); end
	if server_conn then server_conn:close(); end
	initialize();
	return true;
end

local function not_implemented()
	error "not implemented";
end
-- Public API
local _M = {
	lookup = lookup;
	cancel = cancel;
	new_async_socket = not_implemented;
	dns = {
		lookup = lookup_sync;
		cancel = cancel;
		cache = noop;
		socket_wrapper_set = noop;
		settimeout = noop;
		query = noop;
		purge = purge;
		random = noop;
		peek = noop;

		types = types;
		classes = classes;
	};
};

local function lookup_promise(_, qname, qtype, qclass)
	return promise.new(function (resolve, reject)
		local function callback(answer, err)
			if err then
				return reject(err);
			else
				return resolve(answer);
			end
		end
		local ret, err = lookup(callback, qname, qtype, qclass)
		if not ret then reject(err); end
	end);
end

local wrapper = {
	lookup = function (_, callback, qname, qtype, qclass)
		return lookup(callback, qname, qtype, qclass)
	end;
	lookup_promise = lookup_promise;
	_resolver = {
		settimeout = function () end;
		closeall = function () end;
	};
}

_M.instrument = function(measure_) measure = measure_; end;

function _M.resolver() return wrapper; end

return _M;
