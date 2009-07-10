-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local hashes = require "util.hashes"
local xor = require "bit".bxor

local t_insert, t_concat = table.insert, table.concat;
local s_char = string.char;

module "hmac"

local function arraystr(array)
	local t = {}
	for i = 1,#array do
		t_insert(t, s_char(array[i]))
	end

	return t_concat(t)
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
	local opad = {}
	local ipad = {}
	
	for i = 1,blocksize do
		opad[i] = 0x5c
		ipad[i] = 0x36
	end

	if #key > blocksize then
		key = hash(key)
	end

	for i = 1,#key do
		ipad[i] = xor(ipad[i],key:sub(i,i):byte())
		opad[i] = xor(opad[i],key:sub(i,i):byte())
	end

	opad = arraystr(opad)
	ipad = arraystr(ipad)

	if hex then
		return hash(opad..hash(ipad..message), true)
	else
		return hash(opad..hash(ipad..message))
	end
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
