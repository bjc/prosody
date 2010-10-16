-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local hashes = require "util.hashes"

local s_char = string.char;
local s_gsub = string.gsub;
local s_rep = string.rep;

module "hmac"

local xor_map = {0;1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;1;0;3;2;5;4;7;6;9;8;11;10;13;12;15;14;2;3;0;1;6;7;4;5;10;11;8;9;14;15;12;13;3;2;1;0;7;6;5;4;11;10;9;8;15;14;13;12;4;5;6;7;0;1;2;3;12;13;14;15;8;9;10;11;5;4;7;6;1;0;3;2;13;12;15;14;9;8;11;10;6;7;4;5;2;3;0;1;14;15;12;13;10;11;8;9;7;6;5;4;3;2;1;0;15;14;13;12;11;10;9;8;8;9;10;11;12;13;14;15;0;1;2;3;4;5;6;7;9;8;11;10;13;12;15;14;1;0;3;2;5;4;7;6;10;11;8;9;14;15;12;13;2;3;0;1;6;7;4;5;11;10;9;8;15;14;13;12;3;2;1;0;7;6;5;4;12;13;14;15;8;9;10;11;4;5;6;7;0;1;2;3;13;12;15;14;9;8;11;10;5;4;7;6;1;0;3;2;14;15;12;13;10;11;8;9;6;7;4;5;2;3;0;1;15;14;13;12;11;10;9;8;7;6;5;4;3;2;1;0;};
local function xor(x, y)
	local lowx, lowy = x % 16, y % 16;
	local hix, hiy = (x - lowx) / 16, (y - lowy) / 16;
	local lowr, hir = xor_map[lowx * 16 + lowy + 1], xor_map[hix * 16 + hiy + 1];
	local r = hir * 16 + lowr;
	return r;
end
local opadc, ipadc = s_char(0x5c), s_char(0x36);
local ipad_map = {};
local opad_map = {};
for i=0,255 do
	ipad_map[s_char(i)] = s_char(xor(0x36, i));
	opad_map[s_char(i)] = s_char(xor(0x5c, i));
end

--[[
key
	the key to use in the hash
message
	the message to hash
hash
	the hash function
blocksize
	the blocksize for the hash function in bytes
hex
	return raw hash or hexadecimal string
--]]
function hmac(key, message, hash, blocksize, hex)
	if #key > blocksize then
		key = hash(key)
	end

	local padding = blocksize - #key;
	local ipad = s_gsub(key, ".", ipad_map)..s_rep(ipadc, padding);
	local opad = s_gsub(key, ".", opad_map)..s_rep(opadc, padding);

	return hash(opad..hash(ipad..message), hex)
end

function md5(key, message, hex)
	return hmac(key, message, hashes.md5, 64, hex)
end

function sha1(key, message, hex)
	return hmac(key, message, hashes.sha1, 64, hex)
end

function sha256(key, message, hex)
	return hmac(key, message, hashes.sha256, 64, hex)
end

return _M
