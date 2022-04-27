-- util to easily merge multiple sets of LuaSec context options

local type = type;
local pairs = pairs;
local rawset = rawset;
local rawget = rawget;
local error = error;
local t_concat = table.concat;
local t_insert = table.insert;
local setmetatable = setmetatable;
local config_path = prosody.paths.config or ".";
local resolve_path = require"util.paths".resolve_relative_path;

-- TODO: use net.server directly here
local tls_impl  = require"net.tls_luasec";

local _ENV = nil;
-- luacheck: std none

local handlers = { };
local finalisers = { };
local id = function (v) return v end

-- All "handlers" behave like extended rawset(table, key, value) with extra
-- processing usually merging the new value with the old in some reasonable
-- way
-- If a field does not have a defined handler then a new value simply
-- replaces the old.


-- Convert either a list or a set into a special type of set where each
-- item is either positive or negative in order for a later set of options
-- to be able to remove options from this set by filtering out the negative ones
function handlers.options(config, field, new)
	local options = config[field] or { };
	if type(new) ~= "table" then new = { new } end
	for key, value in pairs(new) do
		if value == true or value == false then
			options[key] = value;
		else -- list item
			options[value] = true;
		end
	end
	rawset(config, field, options)
end

handlers.verifyext = handlers.options;

-- finalisers take something produced by handlers and return what luasec
-- expects it to be

-- Produce a list of "positive" options from the set
function finalisers.options(options)
	local output = {};
	for opt, enable in pairs(options) do
		if enable then
			output[#output+1] = opt;
		end
	end
	return output;
end

finalisers.verifyext = finalisers.options;

-- We allow ciphers to be a list

function finalisers.ciphers(cipherlist)
	if type(cipherlist) == "table" then
		return t_concat(cipherlist, ":");
	end
	return cipherlist;
end

-- Curve list too
finalisers.curveslist = finalisers.ciphers;

-- TLS 1.3 ciphers
finalisers.ciphersuites = finalisers.ciphers;

-- Path expansion
function finalisers.key(path)
	if type(path) == "string" then
		return resolve_path(config_path, path);
	else
		return nil
	end
end
finalisers.certificate = finalisers.key;
finalisers.cafile = finalisers.key;
finalisers.capath = finalisers.key;
-- XXX: copied from core/certmanager.lua, but this seems odd, because it would remove a dhparam function from the config
finalisers.dhparam = finalisers.key;

-- protocol = "x" should enable only that protocol
-- protocol = "x+" should enable x and later versions

local protocols = { "sslv2", "sslv3", "tlsv1", "tlsv1_1", "tlsv1_2", "tlsv1_3" };
for i = 1, #protocols do protocols[protocols[i] .. "+"] = i - 1; end

-- this interacts with ssl.options as well to add no_x
local function protocol(config)
	local min_protocol = protocols[config.protocol];
	if min_protocol then
		config.protocol = "sslv23";
		for i = 1, min_protocol do
			t_insert(config.options, "no_"..protocols[i]);
		end
	end
end

-- Merge options from 'new' config into 'config'
local function apply(config, new)
	-- 0 == cache
	rawset(config, 0, nil);
	if type(new) == "table" then
		for field, value in pairs(new) do
			(handlers[field] or rawset)(config, field, value);
		end
	end
	return config
end

-- Finalize the config into the form LuaSec expects
local function final(config)
	local output = { };
	for field, value in pairs(config) do
		output[field] = (finalisers[field] or id)(value);
	end
	-- Need to handle protocols last because it adds to the options list
	protocol(output);
	return output;
end

local function build(config)
	local cached = rawget(config, 0);
	if cached then
		return cached, nil
	end

	local ctx, err = tls_impl.new_context(config:final(), config);
	if ctx then
		rawset(config, 0, ctx);
	end
	return ctx, err
end

local sslopts_mt = {
	__index = {
		apply = apply;
		final = final;
		build = build;
	};
	__newindex = function()
		error("SSL config objects cannot be modified directly. Use :apply()")
	end;
};


local function new()
	return setmetatable({options={}}, sslopts_mt);
end

local function clone(config)
	local result = new();
	for k, v in pairs(config) do
		rawset(result, k, v);
	end
	return result
end

sslopts_mt.__index.clone = clone;

return {
	apply = apply;
	final = final;
	new = new;
};
