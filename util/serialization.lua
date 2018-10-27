-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2018 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local getmetatable = getmetatable;
local next, type = next, type;
local s_format = string.format;
local s_gsub = string.gsub;
local s_rep = string.rep;
local s_char = string.char;
local s_match = string.match;
local t_concat = table.concat;

local pcall = pcall;
local envload = require"util.envload".envload;

local pos_inf, neg_inf = math.huge, -math.huge;
-- luacheck: ignore 143/math
local m_type = math.type or function (n)
	return n % 1 == 0 and n <= 9007199254740992 and n >= -9007199254740992 and "integer" or "float";
end;

local char_to_hex = {};
for i = 0,255 do
	char_to_hex[s_char(i)] = s_format("%02x", i);
end

local function to_hex(s)
	return (s_gsub(s, ".", char_to_hex));
end

local function fatal_error(obj, why)
	error("Can't serialize "..type(obj) .. (why and ": ".. why or ""));
end

local function default_fallback(x, why)
	return s_format("nil --[[%s: %s]]", type(x), why or "fail");
end

local string_escapes = {
	['\a'] = [[\a]]; ['\b'] = [[\b]];
	['\f'] = [[\f]]; ['\n'] = [[\n]];
	['\r'] = [[\r]]; ['\t'] = [[\t]];
	['\v'] = [[\v]]; ['\\'] = [[\\]];
	['\"'] = [[\"]]; ['\''] = [[\']];
}

for i = 0, 255 do
	local c = s_char(i);
	if not string_escapes[c] then
		string_escapes[c] = s_format("\\%03d", i);
	end
end

local default_keywords = {
	["do"] = true; ["and"] = true; ["else"] = true; ["break"] = true;
	["if"] = true; ["end"] = true; ["goto"] = true; ["false"] = true;
	["in"] = true; ["for"] = true; ["then"] = true; ["local"] = true;
	["or"] = true; ["nil"] = true; ["true"] = true; ["until"] = true;
	["elseif"] = true; ["function"] = true; ["not"] = true;
	["repeat"] = true; ["return"] = true; ["while"] = true;
};

local function new(opt)
	if type(opt) ~= "table" then
		opt = { preset = opt };
	end

	local types = {
		table = true;
		string = true;
		number = true;
		boolean = true;
		["nil"] = true;
	};

	-- presets
	if opt.preset == "debug" then
		opt.preset = "oneline";
		opt.freeze = true;
		opt.fatal = false;
		opt.fallback = default_fallback;
	end
	if opt.preset == "oneline" then
		opt.indentwith = opt.indentwith or "";
		opt.itemstart = opt.itemstart or " ";
		opt.itemlast = opt.itemlast or "";
		opt.tend = opt.tend or " }";
	elseif opt.preset == "compact" then
		opt.indentwith = opt.indentwith or "";
		opt.itemstart = opt.itemstart or "";
		opt.itemlast = opt.itemlast or "";
		opt.equals = opt.equals or "=";
	end

	local fallback = opt.fallback or opt.fatal == false and default_fallback or fatal_error;

	local function ser(v)
		return (types[type(v)] or fallback)(v);
	end

	local keywords = opt.keywords or default_keywords;

	-- indented
	local indentwith = opt.indentwith or "\t";
	local itemstart = opt.itemstart or "\n";
	local itemsep = opt.itemsep or ";";
	local itemlast = opt.itemlast or ";\n";
	local tstart = opt.tstart or "{";
	local tend = opt.tend or "}";
	local kstart = opt.kstart or "[";
	local kend = opt.kend or "]";
	local equals = opt.equals or " = ";
	local unquoted = opt.unquoted == nil and "^[%a_][%w_]*$" or opt.unquoted;
	local hex = opt.hex;
	local freeze = opt.freeze;
	local maxdepth = opt.maxdepth or 127;
	local multirefs = opt.multiref;

	-- serialize one table, recursively
	-- t - table being serialized
	-- o - array where tokens are added, concatenate to get final result
	--   - also used to detect cycles
	-- l - position in o of where to insert next token
	-- d - depth, used for indentation
	local function serialize_table(t, o, l, d)
		if o[t] then
			o[l], l = fallback(t, "table has multiple references"), l + 1;
			return l;
		elseif d > maxdepth then
			o[l], l = fallback(t, "max table depth reached"), l + 1;
			return l;
		end

		-- Keep track of table loops
		local ot = t; -- reference pre-freeze
		o[t] = true;
		o[ot] = true;

		if freeze == true then
			-- opportunity to do pre-serialization
			local mt = getmetatable(t);
			if type(mt) == "table" then
				local tag = mt.__name;
				local fr = mt.__freeze;

				if type(fr) == "function" then
					t = fr(t);
					if type(tag) == "string" then
						o[l], l = tag, l + 1;
					end
				end
			end
		end

		o[l], l = tstart, l + 1;
		local indent = s_rep(indentwith, d);
		local numkey = 1;
		local ktyp, vtyp;
		for k,v in next,t do
			o[l], l = itemstart, l + 1;
			o[l], l = indent, l + 1;
			ktyp, vtyp = type(k), type(v);
			if k == numkey then
				-- next index in array part
				-- assuming that these are found in order
				numkey = numkey + 1;
			elseif unquoted and ktyp == "string" and
				not keywords[k] and s_match(k, unquoted) then
				-- unquoted keys
				o[l], l = k, l + 1;
				o[l], l = equals, l + 1;
			else
				-- quoted keys
				o[l], l = kstart, l + 1;
				if ktyp == "table" then
					l = serialize_table(k, o, l, d+1);
				else
					o[l], l = ser(k), l + 1;
				end
				-- =
				o[l], o[l+1], l = kend, equals, l + 2;
			end

			-- the value
			if vtyp == "table" then
				l = serialize_table(v, o, l, d+1);
			else
				o[l], l = ser(v), l + 1;
			end
			-- last item?
			if next(t, k) ~= nil then
				o[l], l = itemsep, l + 1;
			else
				o[l], l = itemlast, l + 1;
			end
		end
		if next(t) ~= nil then
			o[l], l = s_rep(indentwith, d-1), l + 1;
		end
		o[l], l = tend, l +1;

		if multirefs then
			o[t] = nil;
			o[ot] = nil;
		end

		return l;
	end

	function types.table(t)
		local o = {};
		serialize_table(t, o, 1, 1);
		return t_concat(o);
	end

	local function serialize_string(s)
		return '"' .. s_gsub(s, "[%z\1-\31\"\'\\\127-\255]", string_escapes) .. '"';
	end

	if type(hex) == "string" then
		function types.string(s)
			local esc = serialize_string(s);
			if #esc > (#s*2+2+#hex) then
				return hex .. '"' .. to_hex(s) .. '"';
			end
			return esc;
		end
	else
		types.string = serialize_string;
	end

	function types.number(t)
		if m_type(t) == "integer" then
			return s_format("%d", t);
		elseif t == pos_inf then
			return "(1/0)";
		elseif t == neg_inf then
			return "(-1/0)";
		elseif t ~= t then
			return "(0/0)";
		end
		return s_format("%.18g", t);
	end

	-- Are these faster than tostring?
	types["nil"] = function()
		return "nil";
	end

	function types.boolean(t)
		return t and "true" or "false";
	end

	return ser;
end

local function deserialize(str)
	if type(str) ~= "string" then return nil; end
	str = "return "..str;
	local f, err = envload(str, "=serialized data", {});
	if not f then return nil, err; end
	local success, ret = pcall(f);
	if not success then return nil, ret; end
	return ret;
end

return {
	new = new;
	serialize = function (x, opt)
		return new(opt)(x);
	end;
	deserialize = deserialize;
};
