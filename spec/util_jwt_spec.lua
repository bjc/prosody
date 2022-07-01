local jwt = require "util.jwt";

describe("util.jwt", function ()
	it("validates", function ()
		local key = "secret";
		local token = jwt.sign(key, { payload = "this" });
		assert.string(token);
		local ok, parsed = jwt.verify(key, token);
		assert.truthy(ok)
		assert.same({ payload = "this" }, parsed);
	end);
	it("rejects invalid", function ()
		local key = "secret";
		local token = jwt.sign("wrong", { payload = "this" });
		assert.string(token);
		local ok = jwt.verify(key, token);
		assert.falsy(ok)
	end);

	it("validates ES256", function ()
		local private_key = [[
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgevZzL1gdAFr88hb2
OF/2NxApJCzGCEDdfSp6VQO30hyhRANCAAQRWz+jn65BtOMvdyHKcvjBeBSDZH2r
1RTwjmYSi9R/zpBnuQ4EiMnCqfMPWiZqB4QdbAd0E7oH50VpuZ1P087G
-----END PRIVATE KEY-----
]];

		local sign = jwt.new_signer("ES256", private_key);

		local token = sign({
			sub = "1234567890";
			name = "John Doe";
			admin = true;
			iat = 1516239022;
		});

		local public_key = [[
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEEVs/o5+uQbTjL3chynL4wXgUg2R9
q9UU8I5mEovUf86QZ7kOBIjJwqnzD1omageEHWwHdBO6B+dFabmdT9POxg==
-----END PUBLIC KEY-----
]];
		local verify = jwt.new_verifier("ES256", public_key);

		local result = {verify(token)};
		assert.same({
			true; -- success
			{     -- payload
				sub = "1234567890";
				name = "John Doe";
				admin = true;
				iat = 1516239022;
			};
		}, result);

		local result = {verify[[eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWUsImlhdCI6MTUxNjIzOTAyMn0.tyh-VfuzIxCyGYDlkBA7DfyjrqmSHu6pQ2hoZuFqUSLPNY2N0mpHb3nk5K17HWP_3cYHBw7AhHale5wky6-sVA]]};
		assert.same({
			true; -- success
			{     -- payload
				sub = "1234567890";
				name = "John Doe";
				admin = true;
				iat = 1516239022;
			};
		}, result);
	end);

end);

