-- Test vectors from RFC 6070
local hashes = require "util.hashes";
local hex = require "util.hex";

-- Also see spec for util.hmac where HMAC test cases reside

describe("PBKDF2-SHA1", function ()
	it("test vector 1", function ()
		local P = "password"
		local S = "salt"
		local c = 1
		local DK = "0c60c80f961f0e71f3a9b524af6012062fe037a6";
		assert.equal(DK, hex.to(hashes.scram_Hi_sha1(P, S, c)));
	end);
	it("test vector 2", function ()
		local P = "password"
		local S = "salt"
		local c = 2
		local DK = "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957";
		assert.equal(DK, hex.to(hashes.scram_Hi_sha1(P, S, c)));
	end);
	it("test vector 3", function ()
		local P = "password"
		local S = "salt"
		local c = 4096
		local DK = "4b007901b765489abead49d926f721d065a429c1";
		assert.equal(DK, hex.to(hashes.scram_Hi_sha1(P, S, c)));
	end);
	it("test vector 4 #SLOW", function ()
		local P = "password"
		local S = "salt"
		local c = 16777216
		local DK = "eefe3d61cd4da4e4e9945b3d6ba2158c2634e984";
		assert.equal(DK, hex.to(hashes.scram_Hi_sha1(P, S, c)));
	end);
	it("test vector 5", function ()
		local P = "passwordPASSWORDpassword"
		local S = "saltSALTsaltSALTsaltSALTsaltSALTsalt"
		local c = 4096
		local dkLen = 25
		local DK = "3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038"
		assert.equal(DK, hex.to(hashes.scram_Hi_sha1(P, S, c, dkLen)));
	end);
	it("works", function ()
		local P = "pass\0word"
		local S = "sa\0lt"
		local c = 4096
		local dkLen = 16
		local DK = "56fa6aa75548099dcc37d7f03425e0c3"
		assert.equal(DK, hex.to(hashes.scram_Hi_sha1(P, S, c, dkLen)));
	end);
end);

