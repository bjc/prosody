
local file = nil;
local last = nil;
local function read(expected)
	local ch;
	if last then
		ch = last; last = nil;
	else ch = file:read(1); end
	if expected and ch ~= expected then error("expected: "..expected.."; got: "..(ch or "nil")); end
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

local _A, _a, _Z, _z, _0, _9, __, _space = string.byte("AaZz09_ ", 1, 8);
local function isAlpha(ch)
	ch = string.byte(ch) or 0;
	return (ch >= _A and ch <= _Z) or (ch >= _a and ch <= _z);
end
local function isNumeric(ch)
	ch = string.byte(ch) or 0;
	return (ch >= _0 and ch <= _9);
end
local function isVar(ch)
	ch = string.byte(ch) or 0;
	return (ch >= _A and ch <= _Z) or (ch >= _a and ch <= _z) or (ch >= _0 and ch <= _9) or ch == __;
end
local function isSpace(ch)
	ch = string.byte(ch) or "x";
	return ch <= _space;
end

local function readString()
	read("\""); -- skip quote
	local slash = nil;
	local str = "";
	while true do
		local ch = read();
		if ch == "\"" and not slash then break; end
		str = str..ch;
	end
	str = str:gsub("\\.", {["\\b"]="\b", ["\\d"]="\d", ["\\e"]="\e", ["\\f"]="\f", ["\\n"]="\n", ["\\r"]="\r", ["\\s"]="\s", ["\\t"]="\t", ["\\v"]="\v", ["\\\""]="\"", ["\\'"]="'", ["\\\\"]="\\"});
	return str;
end
local function readSpecialString()
	read("<"); read("<"); -- read <<
	local str = "";
	if peek() == "\"" then
		local str = readString();
	elseif peek() ~= ">" then
		error();
	end
	read(">"); read(">"); -- read >>
	return str;
end
local function readVar()
	local var = read();
	while isVar(peek()) do
		var = var..read();
	end
	return var;
end
local function readNumber()
	local num = read();
	while isNumeric(peek()) do
		num = num..read();
	end
	return tonumber(num);
end
local readItem = nil;
local function readTuple()
	local t = {};
	read(); -- read { or [
	while true do
		local item = readItem();
		if not item then break; end
		table.insert(t, item);
	end
	read(); -- read } or ]
	return t;
end
readItem = function()
	local ch = peek();
	if ch == nil then return nil end
	if ch == "{" or ch == "[" then
		return readTuple();
	elseif isAlpha(ch) then
		return readVar();
	elseif isNumeric(ch) then
		return readNumber();
	elseif ch == "\"" then
		return readString();
	elseif ch == "<" then
		return readSpecialString();
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
