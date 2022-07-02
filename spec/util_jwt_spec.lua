local jwt = require "util.jwt";
local test_keys = require "spec.inputs.test_keys";

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

	it("validates HS256", function ()
		local verify = jwt.new_verifier("HS256", "your-256-bit-secret");

		local result = {verify([[eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c]])};
		assert.same({
			true; -- success
			{     -- payload
				sub = "1234567890";
				name = "John Doe";
				iat = 1516239022;
			};
		}, result);

	end);

	it("validates ES256", function ()
		local private_key = test_keys.ecdsa_private_pem;
		local sign = jwt.new_signer("ES256", private_key);

		local token = sign({
			sub = "1234567890";
			name = "John Doe";
			admin = true;
			iat = 1516239022;
		});

		local public_key = test_keys.ecdsa_public_pem;
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

	it("validates RS256", function ()
		local private_key = test_keys.rsa_private_pem;
		local sign = jwt.new_signer("RS256", private_key);

		local token = sign({
			sub = "1234567890";
			name = "John Doe";
			admin = true;
			iat = 1516239022;
		});

		local public_key = test_keys.rsa_public_pem;
		local verify = jwt.new_verifier("RS256", public_key);

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

		local result = {verify[[eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWUsImlhdCI6MTUxNjIzOTAyMn0.NHVaYe26MbtOYhSKkoKYdFVomg4i8ZJd8_-RU8VNbftc4TSMb4bXP3l3YlNWACwyXPGffz5aXHc6lty1Y2t4SWRqGteragsVdZufDn5BlnJl9pdR_kdVFUsra2rWKEofkZeIC4yWytE58sMIihvo9H1ScmmVwBcQP6XETqYd0aSHp1gOa9RdUPDvoXQ5oqygTqVtxaDr6wUFKrKItgBMzWIdNZ6y7O9E0DhEPTbE9rfBo6KTFsHAZnMg4k68CDp2woYIaXbmYTWcvbzIuHO7_37GT79XdIwkm95QJ7hYC9RiwrV7mesbY4PAahERJawntho0my942XheVLmGwLMBkQ]]};
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

	it("validates PS256", function ()
		local private_key = test_keys.rsa_private_pem;
		local sign = jwt.new_signer("PS256", private_key);

		local token = sign({
			sub = "1234567890";
			name = "John Doe";
			admin = true;
			iat = 1516239022;
		});

		local public_key = test_keys.rsa_public_pem;
		local verify = jwt.new_verifier("PS256", public_key);

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

		local result = {verify[[eyJhbGciOiJQUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWUsImlhdCI6MTUxNjIzOTAyMn0.iOeNU4dAFFeBwNj6qdhdvm-IvDQrTa6R22lQVJVuWJxorJfeQww5Nwsra0PjaOYhAMj9jNMO5YLmud8U7iQ5gJK2zYyepeSuXhfSi8yjFZfRiSkelqSkU19I-Ja8aQBDbqXf2SAWA8mHF8VS3F08rgEaLCyv98fLLH4vSvsJGf6ueZSLKDVXz24rZRXGWtYYk_OYYTVgR1cg0BLCsuCvqZvHleImJKiWmtS0-CymMO4MMjCy_FIl6I56NqLE9C87tUVpo1mT-kbg5cHDD8I7MjCW5Iii5dethB4Vid3mZ6emKjVYgXrtkOQ-JyGMh6fnQxEFN1ft33GX2eRHluK9eg]]};
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

