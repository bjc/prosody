-- Prosody IM
-- Copyright (C) 2013 Florian Zeitz
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local format, char = string.format, string.char;
local pairs, ipairs = pairs, ipairs;
local t_insert, t_concat = table.insert, table.concat;

local url_codes = {};
for i = 0, 255 do
	local c = char(i);
	local u = format("%%%02x", i);
	url_codes[c] = u;
	url_codes[u] = c;
	url_codes[u:upper()] = c;
end
local function urlencode(s)
	return s and (s:gsub("[^a-zA-Z0-9.~_-]", url_codes));
end
local function urldecode(s)
	return s and (s:gsub("%%%x%x", url_codes));
end

local function _formencodepart(s)
	return s and (urlencode(s):gsub("%%20", "+"));
end

local function formencode(form)
	local result = {};
	if form[1] then -- Array of ordered { name, value }
		for _, field in ipairs(form) do
			t_insert(result, _formencodepart(field.name).."=".._formencodepart(field.value));
		end
	else -- Unordered map of name -> value
		for name, value in pairs(form) do
			t_insert(result, _formencodepart(name).."=".._formencodepart(value));
		end
	end
	return t_concat(result, "&");
end

local function formdecode(s)
	if not s:match("=") then return urldecode(s); end
	local r = {};
	for k, v in s:gmatch("([^=&]*)=([^&]*)") do
		k, v = k:gsub("%+", "%%20"), v:gsub("%+", "%%20");
		k, v = urldecode(k), urldecode(v);
		t_insert(r, { name = k, value = v });
		r[k] = v;
	end
	return r;
end

local function contains_token(field, token)
	field = ","..field:gsub("[ \t]", ""):lower()..",";
	return field:find(","..token:lower()..",", 1, true) ~= nil;
end

local function normalize_path(path, is_dir)
	if is_dir then
		if path:sub(-1,-1) ~= "/" then path = path.."/"; end
	else
		if path:sub(-1,-1) == "/" then path = path:sub(1, -2); end
	end
	if path:sub(1,1) ~= "/" then path = "/"..path; end
	return path;
end

--- Parse the RFC 7239 Forwarded header into array of key-value pairs.
local function parse_forwarded(forwarded)
	if type(forwarded) ~= "string" then
		return nil;
	end

	local fwd = {}; -- array
	local cur = {}; -- map, to which we add the next key-value pair
	for key, quoted, value, delim in forwarded:gmatch("(%w+)%s*=%s*(\"?)([^,;\"]+)%2%s*(.?)") do
		-- FIXME quoted quotes like "foo\"bar"
		-- unlikely when only dealing with IP addresses
		if quoted == '"' then
			value = value:gsub("\\(.)", "%1");
		end

		cur[key:lower()] = value;
		if delim == "" or delim == "," then
			t_insert(fwd, cur)
			if delim == "" then
				-- end of the string
				break;
			end
			cur = {};
		elseif delim ~= ";" then
			-- misparsed
			return false;
		end
	end

	return fwd;
end

return {
	urlencode = urlencode, urldecode = urldecode;
	formencode = formencode, formdecode = formdecode;
	contains_token = contains_token;
	normalize_path = normalize_path;
	parse_forwarded = parse_forwarded;
};
