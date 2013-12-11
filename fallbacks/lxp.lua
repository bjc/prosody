
local coroutine = coroutine;
local tonumber = tonumber;
local string = string;
local setmetatable, getmetatable = setmetatable, getmetatable;
local pairs = pairs;

local deadroutine = coroutine.create(function() end);
coroutine.resume(deadroutine);

module("lxp")

local entity_map = setmetatable({
	["amp"] = "&";
	["gt"] = ">";
	["lt"] = "<";
	["apos"] = "'";
	["quot"] = "\"";
}, {__index = function(_, s)
		if s:sub(1,1) == "#" then
			if s:sub(2,2) == "x" then
				return string.char(tonumber(s:sub(3), 16));
			else
				return string.char(tonumber(s:sub(2)));
			end
		end
	end
});
local function xml_unescape(str)
	return (str:gsub("&(.-);", entity_map));
end
local function parse_tag(s)
	local name,sattr=(s):gmatch("([^%s]+)(.*)")();
	local attr = {};
	for a,b in (sattr):gmatch("([^=%s]+)=['\"]([^'\"]*)['\"]") do attr[a] = xml_unescape(b); end
	return name, attr;
end

local function parser(data, handlers, ns_separator)
	local function read_until(str)
		local pos = data:find(str, nil, true);
		while not pos do
			data = data..coroutine.yield();
			pos = data:find(str, nil, true);
		end
		local r = data:sub(1, pos);
		data = data:sub(pos+1);
		return r;
	end
	local function read_before(str)
		local pos = data:find(str, nil, true);
		while not pos do
			data = data..coroutine.yield();
			pos = data:find(str, nil, true);
		end
		local r = data:sub(1, pos-1);
		data = data:sub(pos);
		return r;
	end
	local function peek()
		while #data == 0 do data = coroutine.yield(); end
		return data:sub(1,1);
	end

	local ns = { xml = "http://www.w3.org/XML/1998/namespace" };
	ns.__index = ns;
	local function apply_ns(name, dodefault)
		local prefix,n = name:match("^([^:]*):(.*)$");
		if prefix and ns[prefix] then
			return ns[prefix]..ns_separator..n;
		end
		if dodefault and ns[""] then
			return ns[""]..ns_separator..name;
		end
		return name;
	end
	local function push(tag, attr)
		ns = setmetatable({}, ns);
		for k,v in pairs(attr) do
			local xmlns = k == "xmlns" and "" or k:match("^xmlns:(.*)$");
			if xmlns then
				ns[xmlns] = v;
				attr[k] = nil;
			end
		end
		local newattr, n = {}, 0;
		for k,v in pairs(attr) do
			n = n+1;
			k = apply_ns(k);
			newattr[n] = k;
			newattr[k] = v;
		end
		tag = apply_ns(tag, true);
		ns[0] = tag;
		ns.__index = ns;
		return tag, newattr;
	end
	local function pop()
		local tag = ns[0];
		ns = getmetatable(ns);
		return tag;
	end

	while true do
		if peek() == "<" then
			local elem = read_until(">"):sub(2,-2);
			if elem:sub(1,1) == "!" or elem:sub(1,1) == "?" then -- neglect comments and processing-instructions
			elseif elem:sub(1,1) == "/" then -- end tag
				elem = elem:sub(2);
				local name = pop();
				handlers:EndElement(name); -- TODO check for start-end tag name match
			elseif elem:sub(-1,-1) == "/" then -- empty tag
				elem = elem:sub(1,-2);
				local name,attr = parse_tag(elem);
				name,attr = push(name,attr);
				handlers:StartElement(name,attr);
				name = pop();
				handlers:EndElement(name);
			else -- start tag
				local name,attr = parse_tag(elem);
				name,attr = push(name,attr);
				handlers:StartElement(name,attr);
			end
		else
			local text = read_before("<");
			handlers:CharacterData(xml_unescape(text));
		end
	end
end

function new(handlers, ns_separator)
	local co = coroutine.create(parser);
	return {
		parse = function(self, data)
			if not data then
				co = deadroutine;
				return true; -- eof
			end
			local success, result = coroutine.resume(co, data, handlers, ns_separator);
			if result then
				co = deadroutine;
				return nil, result; -- error
			end
			return true; -- success
		end;
	};
end

return _M;
