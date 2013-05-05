-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local type = type;
local t_insert, t_concat, t_remove, t_sort = table.insert, table.concat, table.remove, table.sort;
local s_char = string.char;
local tostring, tonumber = tostring, tonumber;
local pairs, ipairs = pairs, ipairs;
local next = next;
local error = error;
local newproxy, getmetatable = newproxy, getmetatable;
local print = print;

local has_array, array = pcall(require, "util.array");
local array_mt = hasarray and getmetatable(array()) or {};

--module("json")
local json = {};

local null = newproxy and newproxy(true) or {};
if getmetatable and getmetatable(null) then
	getmetatable(null).__tostring = function() return "null"; end;
end
json.null = null;

local escapes = {
	["\""] = "\\\"", ["\\"] = "\\\\", ["\b"] = "\\b",
	["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t"};
local unescapes = {
	["\""] = "\"", ["\\"] = "\\", ["/"] = "/",
	b = "\b", f = "\f", n = "\n", r = "\r", t = "\t"};
for i=0,31 do
	local ch = s_char(i);
	if not escapes[ch] then escapes[ch] = ("\\u%.4X"):format(i); end
end

local function codepoint_to_utf8(code)
	if code < 0x80 then return s_char(code); end
	local bits0_6 = code % 64;
	if code < 0x800 then
		local bits6_5 = (code - bits0_6) / 64;
		return s_char(0x80 + 0x40 + bits6_5, 0x80 + bits0_6);
	end
	local bits0_12 = code % 4096;
	local bits6_6 = (bits0_12 - bits0_6) / 64;
	local bits12_4 = (code - bits0_12) / 4096;
	return s_char(0x80 + 0x40 + 0x20 + bits12_4, 0x80 + bits6_6, 0x80 + bits0_6);
end

local valid_types = {
	number  = true,
	string  = true,
	table   = true,
	boolean = true
};
local special_keys = {
	__array = true;
	__hash  = true;
};

local simplesave, tablesave, arraysave, stringsave;

function stringsave(o, buffer)
	-- FIXME do proper utf-8 and binary data detection
	t_insert(buffer, "\""..(o:gsub(".", escapes)).."\"");
end

function arraysave(o, buffer)
	t_insert(buffer, "[");
	if next(o) then
		for i,v in ipairs(o) do
			simplesave(v, buffer);
			t_insert(buffer, ",");
		end
		t_remove(buffer);
	end
	t_insert(buffer, "]");
end

function tablesave(o, buffer)
	local __array = {};
	local __hash = {};
	local hash = {};
	for i,v in ipairs(o) do
		__array[i] = v;
	end
	for k,v in pairs(o) do
		local ktype, vtype = type(k), type(v);
		if valid_types[vtype] or v == null then
			if ktype == "string" and not special_keys[k] then
				hash[k] = v;
			elseif (valid_types[ktype] or k == null) and __array[k] == nil then
				__hash[k] = v;
			end
		end
	end
	if next(__hash) ~= nil or next(hash) ~= nil or next(__array) == nil then
		t_insert(buffer, "{");
		local mark = #buffer;
		if buffer.ordered then
			local keys = {};
			for k in pairs(hash) do
				t_insert(keys, k);
			end
			t_sort(keys);
			for _,k in ipairs(keys) do
				stringsave(k, buffer);
				t_insert(buffer, ":");
				simplesave(hash[k], buffer);
				t_insert(buffer, ",");
			end
		else
			for k,v in pairs(hash) do
				stringsave(k, buffer);
				t_insert(buffer, ":");
				simplesave(v, buffer);
				t_insert(buffer, ",");
			end
		end
		if next(__hash) ~= nil then
			t_insert(buffer, "\"__hash\":[");
			for k,v in pairs(__hash) do
				simplesave(k, buffer);
				t_insert(buffer, ",");
				simplesave(v, buffer);
				t_insert(buffer, ",");
			end
			t_remove(buffer);
			t_insert(buffer, "]");
			t_insert(buffer, ",");
		end
		if next(__array) then
			t_insert(buffer, "\"__array\":");
			arraysave(__array, buffer);
			t_insert(buffer, ",");
		end
		if mark ~= #buffer then t_remove(buffer); end
		t_insert(buffer, "}");
	else
		arraysave(__array, buffer);
	end
end

function simplesave(o, buffer)
	local t = type(o);
	if t == "number" then
		t_insert(buffer, tostring(o));
	elseif t == "string" then
		stringsave(o, buffer);
	elseif t == "table" then
		local mt = getmetatable(o);
		if mt == array_mt then
			arraysave(o, buffer);
		else
			tablesave(o, buffer);
		end
	elseif t == "boolean" then
		t_insert(buffer, (o and "true" or "false"));
	else
		t_insert(buffer, "null");
	end
end

function json.encode(obj)
	local t = {};
	simplesave(obj, t);
	return t_concat(t);
end
function json.encode_ordered(obj)
	local t = { ordered = true };
	simplesave(obj, t);
	return t_concat(t);
end
function json.encode_array(obj)
	local t = {};
	arraysave(obj, t);
	return t_concat(t);
end

-----------------------------------


function json.decode(json)
	json = json.." "; -- appending a space ensures valid json wouldn't touch EOF
	local pos = 1;
	local current = {};
	local stack = {};
	local ch, peek;
	local function next()
		ch = json:sub(pos, pos);
		if ch == "" then error("Unexpected EOF"); end
		pos = pos+1;
		peek = json:sub(pos, pos);
		return ch;
	end
	
	local function skipwhitespace()
		while ch and (ch == "\r" or ch == "\n" or ch == "\t" or ch == " ") do
			next();
		end
	end
	local function skiplinecomment()
		repeat next(); until not(ch) or ch == "\r" or ch == "\n";
		skipwhitespace();
	end
	local function skipstarcomment()
		next(); next(); -- skip '/', '*'
		while peek and ch ~= "*" and peek ~= "/" do next(); end
		if not peek then error("eof in star comment") end
		next(); next(); -- skip '*', '/'
		skipwhitespace();
	end
	local function skipstuff()
		while true do
			skipwhitespace();
			if ch == "/" and peek == "*" then
				skipstarcomment();
			elseif ch == "/" and peek == "/" then
				skiplinecomment();
			else
				return;
			end
		end
	end
	
	local readvalue;
	local function readarray()
		local t = setmetatable({}, array_mt);
		next(); -- skip '['
		skipstuff();
		if ch == "]" then next(); return t; end
		t_insert(t, readvalue());
		while true do
			skipstuff();
			if ch == "]" then next(); return t; end
			if not ch then error("eof while reading array");
			elseif ch == "," then next();
			elseif ch then error("unexpected character in array, comma expected"); end
			if not ch then error("eof while reading array"); end
			t_insert(t, readvalue());
		end
	end
	
	local function checkandskip(c)
		local x = ch or "eof";
		if x ~= c then error("unexpected "..x..", '"..c.."' expected"); end
		next();
	end
	local function readliteral(lit, val)
		for c in lit:gmatch(".") do
			checkandskip(c);
		end
		return val;
	end
	local function readstring()
		local s = {};
		checkandskip("\"");
		while ch do
			while ch and ch ~= "\\" and ch ~= "\"" do
				t_insert(s, ch); next();
			end
			if ch == "\\" then
				next();
				if unescapes[ch] then
					t_insert(s, unescapes[ch]);
					next();
				elseif ch == "u" then
					local seq = "";
					for i=1,4 do
						next();
						if not ch then error("unexpected eof in string"); end
						if not ch:match("[0-9a-fA-F]") then error("invalid unicode escape sequence in string"); end
						seq = seq..ch;
					end
					t_insert(s, codepoint_to_utf8(tonumber(seq, 16)));
					next();
				else error("invalid escape sequence in string"); end
			end
			if ch == "\"" then
				next();
				return t_concat(s);
			end
		end
		error("eof while reading string");
	end
	local function readnumber()
		local s = "";
		if ch == "-" then
			s = s..ch; next();
			if not ch:match("[0-9]") then error("number format error"); end
		end
		if ch == "0" then
			s = s..ch; next();
			if ch:match("[0-9]") then error("number format error"); end
		else
			while ch and ch:match("[0-9]") do
				s = s..ch; next();
			end
		end
		if ch == "." then
			s = s..ch; next();
			if not ch:match("[0-9]") then error("number format error"); end
			while ch and ch:match("[0-9]") do
				s = s..ch; next();
			end
			if ch == "e" or ch == "E" then
				s = s..ch; next();
				if ch == "+" or ch == "-" then
					s = s..ch; next();
					if not ch:match("[0-9]") then error("number format error"); end
					while ch and ch:match("[0-9]") do
						s = s..ch; next();
					end
				end
			end
		end
		return tonumber(s);
	end
	local function readmember(t)
		skipstuff();
		local k = readstring();
		skipstuff();
		checkandskip(":");
		t[k] = readvalue();
	end
	local function fixobject(obj)
		local __array = obj.__array;
		if __array then
			obj.__array = nil;
			for i,v in ipairs(__array) do
				t_insert(obj, v);
			end
		end
		local __hash = obj.__hash;
		if __hash then
			obj.__hash = nil;
			local k;
			for i,v in ipairs(__hash) do
				if k ~= nil then
					obj[k] = v; k = nil;
				else
					k = v;
				end
			end
		end
		return obj;
	end
	local function readobject()
		local t = {};
		next(); -- skip '{'
		skipstuff();
		if ch == "}" then next(); return t; end
		if not ch then error("eof while reading object"); end
		readmember(t);
		while true do
			skipstuff();
			if ch == "}" then next(); return fixobject(t); end
			if not ch then error("eof while reading object");
			elseif ch == "," then next();
			elseif ch then error("unexpected character in object, comma expected"); end
			if not ch then error("eof while reading object"); end
			readmember(t);
		end
	end
	
	function readvalue()
		skipstuff();
		while ch do
			if ch == "{" then
				return readobject();
			elseif ch == "[" then
				return readarray();
			elseif ch == "\"" then
				return readstring();
			elseif ch:match("[%-0-9%.]") then
				return readnumber();
			elseif ch == "n" then
				return readliteral("null", null);
			elseif ch == "t" then
				return readliteral("true", true);
			elseif ch == "f" then
				return readliteral("false", false);
			else
				error("invalid character at value start: "..ch);
			end
		end
		error("eof while reading value");
	end
	next();
	return readvalue();
end

function json.test(object)
	local encoded = json.encode(object);
	local decoded = json.decode(encoded);
	local recoded = json.encode(decoded);
	if encoded ~= recoded then
		print("FAILED");
		print("encoded:", encoded);
		print("recoded:", recoded);
	else
		print(encoded);
	end
	return encoded == recoded;
end

return json;
