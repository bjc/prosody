-- Prosody IM
-- Copyright (C) 2021 Prosody folks
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

--[[
This file provides a shim abstraction over LuaSec, consolidating some code
which was previously spread between net.server backends, portmanager and
certmanager.

The goal is to provide a more or less well-defined API on top of LuaSec which
abstracts away some of the things which are not needed and simplifies usage of
commonly used things (such as SNI contexts). Eventually, network backends
which do not rely on LuaSocket+LuaSec should be able to provide *this* API
instead of having to mimic LuaSec.
]]
local softreq = require"util.dependencies".softreq;
local ssl = softreq"ssl";
local ssl_newcontext = ssl.newcontext;
local ssl_context = ssl.context or softreq"ssl.context";
local io_open = io.open;

local context_api = {};
local context_mt = {__index = context_api};

function context_api:set_sni_host(host, cert, key)
	local ctx, err = self._builder:clone():apply({
		certificate = cert,
		key = key,
	}):build();
	if not ctx then
		return false, err
	end

	self._sni_contexts[host] = ctx._inner

	return true, nil
end

function context_api:remove_sni_host(host)
	self._sni_contexts[host] = nil
end

function context_api:wrap(sock)
	local ok, conn, err = pcall(ssl.wrap, sock, self._inner);
	if not ok then
		return nil, err
	end
	return conn, nil
end

local function new_context(cfg, builder)
	-- LuaSec expects dhparam to be a callback that takes two arguments.
	-- We ignore those because it is mostly used for having a separate
	-- set of params for EXPORT ciphers, which we don't have by default.
	if type(cfg.dhparam) == "string" then
		local f, err = io_open(cfg.dhparam);
		if not f then return nil, "Could not open DH parameters: "..err end
		local dhparam = f:read("*a");
		f:close();
		cfg.dhparam = function() return dhparam; end
	end

	local inner, err = ssl_newcontext(cfg);
	if not inner then
		return nil, err
	end

	-- COMPAT Older LuaSec ignores the cipher list from the config, so we have to take care
	-- of it ourselves (W/A for #x)
	if inner and cfg.ciphers then
		local success;
		success, err = ssl_context.setcipher(inner, cfg.ciphers);
		if not success then
			return nil, err
		end
	end

	return setmetatable({
		_inner = inner,
		_builder = builder,
		_sni_contexts = {},
	}, context_mt), nil
end

return {
	new_context = new_context,
};
