-- Test cases from RFC 4231

-- Yes, the lines are long, it's annoying to split the long hex things.
-- luacheck: ignore 631

local hmac = require "util.hmac";
local hex = require "util.hex";

describe("Test case 1", function ()
	local Key  = hex.from("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");
	local Data = hex.from("4869205468657265");
	describe("HMAC-SHA-256", function ()
		it("works", function()
			assert.equal("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", hmac.sha256(Key, Data, true))
		end);
	end);
	describe("HMAC-SHA-512", function ()
		it("works", function()
			assert.equal("87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854", hmac.sha512(Key, Data, true))
		end);
	end);
end);
describe("Test case 2", function ()
	local Key  = hex.from("4a656665");
	local Data = hex.from("7768617420646f2079612077616e7420666f72206e6f7468696e673f");
	describe("HMAC-SHA-256", function ()
		it("works", function()
			assert.equal("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", hmac.sha256(Key, Data, true))
		end);
	end);
	describe("HMAC-SHA-512", function ()
		it("works", function()
			assert.equal("164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737", hmac.sha512(Key, Data, true))
		end);
	end);
end);
describe("Test case 3", function ()
	local Key  = hex.from("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
	local Data = hex.from("dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd");
	describe("HMAC-SHA-256", function ()
		it("works", function()
			assert.equal("773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe", hmac.sha256(Key, Data, true))
		end);
	end);
	describe("HMAC-SHA-512", function ()
		it("works", function()
			assert.equal("fa73b0089d56a284efb0f0756c890be9b1b5dbdd8ee81a3655f83e33b2279d39bf3e848279a722c806b485a47e67c807b946a337bee8942674278859e13292fb", hmac.sha512(Key, Data, true))
		end);
	end);
end);
describe("Test case 4", function ()
	local Key  = hex.from("0102030405060708090a0b0c0d0e0f10111213141516171819");
	local Data = hex.from("cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd");
	describe("HMAC-SHA-256", function ()
		it("works", function()
			assert.equal("82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b", hmac.sha256(Key, Data, true))
		end);
	end);
	describe("HMAC-SHA-512", function ()
		it("works", function()
			assert.equal("b0ba465637458c6990e5a8c5f61d4af7e576d97ff94b872de76f8050361ee3dba91ca5c11aa25eb4d679275cc5788063a5f19741120c4f2de2adebeb10a298dd", hmac.sha512(Key, Data, true))
		end);
	end);
end);
describe("Test case 5", function ()
	local Key  = hex.from("0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c");
	local Data = hex.from("546573742057697468205472756e636174696f6e");
	describe("HMAC-SHA-256", function ()
		it("works", function()
			assert.equal("a3b6167473100ee06e0c796c2955552b", hmac.sha256(Key, Data, true):sub(1,128/4))
		end);
	end);
	describe("HMAC-SHA-512", function ()
		it("works", function()
			assert.equal("415fad6271580a531d4179bc891d87a6", hmac.sha512(Key, Data, true):sub(1,128/4))
		end);
	end);
end);
describe("Test case 6", function ()
	local Key  = hex.from("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
	local Data = hex.from("54657374205573696e67204c6172676572205468616e20426c6f636b2d53697a65204b6579202d2048617368204b6579204669727374");
	describe("HMAC-SHA-256", function ()
		it("works", function()
			assert.equal("60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54", hmac.sha256(Key, Data, true))
		end);
	end);
	describe("HMAC-SHA-512", function ()
		it("works", function()
			assert.equal("80b24263c7c1a3ebb71493c1dd7be8b49b46d1f41b4aeec1121b013783f8f3526b56d037e05f2598bd0fd2215d6a1e5295e64f73f63f0aec8b915a985d786598", hmac.sha512(Key, Data, true))
		end);
	end);
end);
describe("Test case 7", function ()
	local Key  = hex.from("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
	local Data = hex.from("5468697320697320612074657374207573696e672061206c6172676572207468616e20626c6f636b2d73697a65206b657920616e642061206c6172676572207468616e20626c6f636b2d73697a6520646174612e20546865206b6579206e6565647320746f20626520686173686564206265666f7265206265696e6720757365642062792074686520484d414320616c676f726974686d2e");
	describe("HMAC-SHA-256", function ()
		it("works", function()
			assert.equal("9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2", hmac.sha256(Key, Data, true))
		end);
	end);
	describe("HMAC-SHA-512", function ()
		it("works", function()
			assert.equal("e37b6a775dc87dbaa4dfa9f96e5e3ffddebd71f8867289865df5a32d20cdc944b6022cac3c4982b10d5eeb55c3e4de15134676fb6de0446065c97440fa8c6a58", hmac.sha512(Key, Data, true))
		end);
	end);
end);
