local s_char = string.char;
local s_format = string.format;
local s_gsub = string.gsub;
local s_lower = string.lower;

local char_to_hex = {};
local hex_to_char = {};

do
	local char, hex;
	for i = 0,255 do
		char, hex = s_char(i), s_format("%02x", i);
		char_to_hex[char] = hex;
		hex_to_char[hex] = char;
	end
end

local function to(s)
	return (s_gsub(s, ".", char_to_hex));
end

local function from(s)
	return (s_gsub(s_lower(s), "%X*(%x%x)%X*", hex_to_char));
end

return { to = to, from = from }
