-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local string_byte, string_char = string.byte, string.char;
local t_concat, t_insert = table.concat, table.insert;
local type, tonumber, tostring = type, tonumber, tostring;

local file = nil;
local last = nil;
local line = 1;
local function read(expected)
	local ch;
	if last then
		ch = last; last = nil;
	else
		ch = file:read(1);
		if ch == "\n" then line = line + 1; end
	end
	if expected and ch ~= expected then error("expected: "..expected.."; got: "..(ch or "nil").." on line "..line); end
	return ch;
end
local function pushback(ch)
	if last then error(); end
	last = ch;
end
local function peek()
	if not last then last = read(); end
	return last;
end

local _A, _a, _Z, _z, _0, _9, __, _at, _space, _minus = string_byte("AaZz09@_ -", 1, 10);
local function isLowerAlpha(ch)
	ch = string_byte(ch) or 0;
	return (ch >= _a and ch <= _z);
end
local function isNumeric(ch)
	ch = string_byte(ch) or 0;
	return (ch >= _0 and ch <= _9) or ch == _minus;
end
local function isAtom(ch)
	ch = string_byte(ch) or 0;
	return (ch >= _A and ch <= _Z) or (ch >= _a and ch <= _z) or (ch >= _0 and ch <= _9) or ch == __ or ch == _at;
end
local function isSpace(ch)
	ch = string_byte(ch) or "x";
	return ch <= _space;
end

local escapes = {["\\b"]="\b", ["\\d"]="\127", ["\\e"]="\27", ["\\f"]="\f", ["\\n"]="\n", ["\\r"]="\r", ["\\s"]=" ", ["\\t"]="\t", ["\\v"]="\v", ["\\\""]="\"", ["\\'"]="'", ["\\\\"]="\\"};
local function readString()
	read("\""); -- skip quote
	local slash = nil;
	local str = {};
	while true do
		local ch = read();
		if slash then
			slash = slash..ch;
			if not escapes[slash] then error("Unknown escape sequence: "..slash); end
			str[#str+1] = escapes[slash];
			slash = nil;
		elseif ch == "\"" then
			break;
		elseif ch == "\\" then
			slash = ch;
		else
			str[#str+1] = ch;
		end
	end
	return t_concat(str);
end
local function readAtom1()
	local var = { read() };
	while isAtom(peek()) do
		var[#var+1] = read();
	end
	return t_concat(var);
end
local function readAtom2()
	local str = { read("'") };
	local slash = nil;
	while true do
		local ch = read();
		str[#str+1] = ch;
		if ch == "'" and not slash then break; end
	end
	return t_concat(str);
end
local function readNumber()
	local num = { read() };
	while isNumeric(peek()) do
		num[#num+1] = read();
	end
	if peek() == "." then
		num[#num+1] = read();
		while isNumeric(peek()) do
			num[#num+1] = read();
		end
	end
	return tonumber(t_concat(num));
end
local readItem = nil;
local function readTuple()
	local t = {};
	local s = {}; -- string representation
	read(); -- read {, or [, or <
	while true do
		local item = readItem();
		if not item then break; end
		if type(item) ~= "number" or item > 255 then
			s = nil;
		elseif s then
			s[#s+1] = string_char(item);
		end
		t_insert(t, item);
	end
	read(); -- read }, or ], or >
	if s and #s > 0  then
		return t_concat(s)
	else
		return t
	end;
end
local function readBinary()
	read("<"); -- read <
	-- Discard PIDs
	if isNumeric(peek()) then
		while peek() ~= ">" do read(); end
		read(">");
		return {};
	end
	local t = readTuple();
	read(">") -- read >
	local ch = peek();
	if type(t) == "string" then
		-- binary is a list of integers
		return t;
	elseif type(t) == "table" then
		if t[1] then
			-- binary contains string
			return t[1];
		else
			-- binary is empty
			return "";
		end;
	else
		error();
	end
end
readItem = function()
	local ch = peek();
	if ch == nil then return nil end
	if ch == "{" or ch == "[" then
		return readTuple();
	elseif isLowerAlpha(ch) then
		return readAtom1();
	elseif ch == "'" then
		return readAtom2();
	elseif isNumeric(ch) then
		return readNumber();
	elseif ch == "\"" then
		return readString();
	elseif ch == "<" then
		return readBinary();
	elseif isSpace(ch) or ch == "," or ch == "|" then
		read();
		return readItem();
	else
		--print("Unknown char: "..ch);
		return nil;
	end
end
local function readChunk()
	local x = readItem();
	if x then read("."); end
	return x;
end
local function readFile(filename)
	file = io.open(filename);
	if not file then error("File not found: "..filename); os.exit(0); end
	return function()
		local x = readChunk();
		if not x and peek() then error("Invalid char: "..peek()); end
		return x;
	end;
end

module "erlparse"

function parseFile(file)
	return readFile(file);
end

return _M;
