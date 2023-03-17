-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

-- COMPAT: Only for external pre-0.9 modules

local hashes = require "prosody.util.hashes"

return {
	md5 = hashes.hmac_md5,
	sha1 = hashes.hmac_sha1,
	sha224 = hashes.hmac_sha224,
	sha256 = hashes.hmac_sha256,
	sha384 = hashes.hmac_sha384,
	sha512 = hashes.hmac_sha512,
	blake2s256 = hashes.hmac_blake2s256,
	blake2b512 = hashes.hmac_blake2b512,
};
