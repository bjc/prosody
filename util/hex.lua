local s_char = string.char;

local function char_to_hex(c)
	return ("%02x"):format(c:byte())
end

local function hex_to_char(h)
	return s_char(tonumber(h, 16));
end

local function to(s)
	return s:gsub(".", char_to_hex);
end

local function from(s)
	return s:gsub("..", hex_to_char);
end

return { to = to, from = from }
