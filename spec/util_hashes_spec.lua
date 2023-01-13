-- Test vectors from RFC 6070
local hashes = require "util.hashes";
local hex = require "util.hex";

-- Also see spec for util.hmac where HMAC test cases reside

--luacheck: ignore 631

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

describe("HKDF", function ()
	describe("HMAC-SHA256", function ()
		describe("RFC 5869", function ()
			it("test vector A.1", function ()
				local ikm = hex.decode("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");
				local salt = hex.decode("000102030405060708090a0b0c");
				local info = hex.decode("f0f1f2f3f4f5f6f7f8f9");

				local expected = "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865";

				local ret = hashes.hkdf_hmac_sha256(42, ikm, salt, info);
				assert.equal(expected, hex.encode(ret));
			end);

			it("test vector A.2", function ()
				local ikm = hex.decode("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f");
				local salt = hex.decode("606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeaf");
				local info = hex.decode("b0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff");

				local expected = "b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71cc30c58179ec3e87c14c01d5c1f3434f1d87";

				local ret = hashes.hkdf_hmac_sha256(82, ikm, salt, info);
				assert.equal(expected, hex.encode(ret));
			end);

			it("test vector A.3", function ()
				local ikm = hex.decode("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");
				local salt = "";
				local info = "";

				local expected = "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8";

				local ret = hashes.hkdf_hmac_sha256(42, ikm, salt, info);
				assert.equal(expected, hex.encode(ret));
			end);
		end);
	end);
end);
