-- Prosody IM
-- Copyright (C) 2008-2017 Matthew Wild
-- Copyright (C) 2008-2017 Waqas Hussain
-- Copyright (C) 2011-2017 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- XEP-0313: Message Archive Management for Prosody
--

local stanza = require"prosody.util.stanza".stanza;
local tonumber = tonumber;
local s_format = string.format;
local type = type;
local pairs = pairs;

local function inttostr(n)
	return s_format("%d", n);
end

local xmlns_rsm = 'http://jabber.org/protocol/rsm';

local element_parsers = {};

do
	local parsers = element_parsers;
	local function xs_int(st)
		return tonumber((st:get_text()));
	end
	local function xs_string(st)
		return st:get_text();
	end

	parsers.after = xs_string;
	parsers.before = function(st)
			local text = st:get_text();
			return text == "" or text;
		end;
	parsers.max = xs_int;
	parsers.index = xs_int;

	parsers.first = function(st)
			return { index = tonumber(st.attr.index); st:get_text() };
		end;
	parsers.last = xs_string;
	parsers.count = xs_int;
end

local element_generators = setmetatable({
	first = function(st, data)
		if type(data) == "table" then
			st:tag("first", { index = inttostr(data.index) }):text(data[1]):up();
		else
			st:text_tag("first", data);
		end
	end;
	before = function(st, data)
		if data == true then
			st:tag("before"):up();
		else
			st:text_tag("before", data);
		end
	end;
	max = function (st, data)
		st:text_tag("max", inttostr(data));
	end;
	index = function (st, data)
		st:text_tag("index", inttostr(data));
	end;
	count = function (st, data)
		st:text_tag("count", inttostr(data));
	end;
}, {
	__index = function(_, name)
		return function(st, data)
			st:text_tag(name, data);
		end
	end;
});


local function parse(set)
	local rs = {};
	for tag in set:childtags() do
		local name = tag.name;
		local parser = name and element_parsers[name];
		if parser then
			rs[name] = parser(tag);
		end
	end
	return rs;
end

local function generate(t)
	local st = stanza("set", { xmlns = xmlns_rsm });
	for k,v in pairs(t) do
		if element_parsers[k] then
			element_generators[k](st, v);
		end
	end
	return st;
end

local function get(st)
	local set = st:get_child("set", xmlns_rsm);
	if set and #set.tags > 0 then
		return parse(set);
	end
end

return { parse = parse, generate = generate, get = get };
