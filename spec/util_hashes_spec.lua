-- Test vectors from RFC 6070
local hashes = require "util.hashes";
local hex = require "util.hex";

-- Also see spec for util.hmac where HMAC test cases reside

describe("PBKDF2-HMAC-SHA1", function ()
	it("test vector 1", function ()
		local P = "password"
		local S = "salt"
		local c = 1
		local DK = "0c60c80f961f0e71f3a9b524af6012062fe037a6";
		assert.equal(DK, hex.encode(hashes.pbkdf2_hmac_sha1(P, S, c)));
	end);
	it("test vector 2", function ()
		local P = "password"
		local S = "salt"
		local c = 2
		local DK = "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957";
		assert.equal(DK, hex.encode(hashes.pbkdf2_hmac_sha1(P, S, c)));
	end);
	it("test vector 3", function ()
		local P = "password"
		local S = "salt"
		local c = 4096
		local DK = "4b007901b765489abead49d926f721d065a429c1";
		assert.equal(DK, hex.encode(hashes.pbkdf2_hmac_sha1(P, S, c)));
	end);
	it("test vector 4 #SLOW", function ()
		local P = "password"
		local S = "salt"
		local c = 16777216
		local DK = "eefe3d61cd4da4e4e9945b3d6ba2158c2634e984";
		assert.equal(DK, hex.encode(hashes.pbkdf2_hmac_sha1(P, S, c)));
	end);
end);

describe("PBKDF2-HMAC-SHA256", function ()
	it("test vector 1", function ()
		local P = "password";
		local S = "salt";
		local c = 1
		local DK = "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b";
		assert.equal(DK, hex.encode(hashes.pbkdf2_hmac_sha256(P, S, c)));
	end);
	it("test vector 2", function ()
		local P = "password";
		local S = "salt";
		local c = 2
		local DK = "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43";
		assert.equal(DK, hex.encode(hashes.pbkdf2_hmac_sha256(P, S, c)));
	end);
end);


describe("SHA-3", function ()
	describe("256", function ()
		it("works", function ()
			local expected = "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a"
			assert.equal(expected, hashes.sha3_256("", true));
		end);
	end);
	describe("512", function ()
		it("works", function ()
			local expected = "a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a615b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26"
			assert.equal(expected, hashes.sha3_512("", true));
		end);
	end);
end);

