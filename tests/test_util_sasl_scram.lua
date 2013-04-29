

local hmac_sha1 = require "util.hashes".hmac_sha1;
local function toHex(s)
	return s and (s:gsub(".", function (c) return ("%02x"):format(c:byte()); end));
end

function Hi(Hi)
	assert( toHex(Hi(hmac_sha1, "password", "salt", 1)) == "0c60c80f961f0e71f3a9b524af6012062fe037a6",
	[[FAIL: toHex(Hi(hmac_sha1, "password", "salt", 1)) == "0c60c80f961f0e71f3a9b524af6012062fe037a6"]])
	assert( toHex(Hi(hmac_sha1, "password", "salt", 2)) == "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957",
	[[FAIL: toHex(Hi(hmac_sha1, "password", "salt", 2)) == "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957"]])
	assert( toHex(Hi(hmac_sha1, "password", "salt", 64)) == "a7bc9b6efea2cbd717da72d83bfcc4e17d0b6280",
	[[FAIL: toHex(Hi(hmac_sha1, "password", "salt", 64)) == "a7bc9b6efea2cbd717da72d83bfcc4e17d0b6280"]])
	assert( toHex(Hi(hmac_sha1, "password", "salt", 4096)) == "4b007901b765489abead49d926f721d065a429c1",
	[[FAIL: toHex(Hi(hmac_sha1, "password", "salt", 4096)) == "4b007901b765489abead49d926f721d065a429c1"]])
	-- assert( toHex(Hi(hmac_sha1, "password", "salt", 16777216)) == "eefe3d61cd4da4e4e9945b3d6ba2158c2634e984",
	-- [[FAIL: toHex(Hi(hmac_sha1, "password", "salt", 16777216)) == "eefe3d61cd4da4e4e9945b3d6ba2158c2634e984"]])
end

function init(init)
	-- no tests
end
