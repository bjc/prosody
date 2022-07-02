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

	local test_cases = {
		{
			algorithm = "HS256";
			keys = {
				{ "your-256-bit-secret", "your-256-bit-secret" };
				{ "another-secret", "another-secret" };
			};
			{
				name = "jwt.io reference";
				[[eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c]];
				{     -- payload
					sub = "1234567890";
					name = "John Doe";
					iat = 1516239022;
				};
			};
		};
		{
			algorithm = "ES256";
			keys = {
				{ test_keys.ecdsa_private_pem, test_keys.ecdsa_public_pem };
				{ test_keys.alt_ecdsa_private_pem, test_keys.alt_ecdsa_public_pem };
			};
			{
				name = "jwt.io reference";
				[[eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWUsImlhdCI6MTUxNjIzOTAyMn0.tyh-VfuzIxCyGYDlkBA7DfyjrqmSHu6pQ2hoZuFqUSLPNY2N0mpHb3nk5K17HWP_3cYHBw7AhHale5wky6-sVA]];
				{     -- payload
					sub = "1234567890";
					name = "John Doe";
					admin = true;
					iat = 1516239022;
				};
			};
		};
		{
			algorithm = "RS256";
			keys = {
				{ test_keys.rsa_private_pem, test_keys.rsa_public_pem };
				{ test_keys.alt_rsa_private_pem, test_keys.alt_rsa_public_pem };
			};
			{
				name = "jwt.io reference";
				[[eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWUsImlhdCI6MTUxNjIzOTAyMn0.NHVaYe26MbtOYhSKkoKYdFVomg4i8ZJd8_-RU8VNbftc4TSMb4bXP3l3YlNWACwyXPGffz5aXHc6lty1Y2t4SWRqGteragsVdZufDn5BlnJl9pdR_kdVFUsra2rWKEofkZeIC4yWytE58sMIihvo9H1ScmmVwBcQP6XETqYd0aSHp1gOa9RdUPDvoXQ5oqygTqVtxaDr6wUFKrKItgBMzWIdNZ6y7O9E0DhEPTbE9rfBo6KTFsHAZnMg4k68CDp2woYIaXbmYTWcvbzIuHO7_37GT79XdIwkm95QJ7hYC9RiwrV7mesbY4PAahERJawntho0my942XheVLmGwLMBkQ]];
				{     -- payload
					sub = "1234567890";
					name = "John Doe";
					admin = true;
					iat = 1516239022;
				};
			};
		};
		{
			algorithm = "PS256";
			keys = {
				{ test_keys.rsa_private_pem, test_keys.rsa_public_pem };
				{ test_keys.alt_rsa_private_pem, test_keys.alt_rsa_public_pem };
			};
			{
				name = "jwt.io reference";
				[[eyJhbGciOiJQUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWUsImlhdCI6MTUxNjIzOTAyMn0.iOeNU4dAFFeBwNj6qdhdvm-IvDQrTa6R22lQVJVuWJxorJfeQww5Nwsra0PjaOYhAMj9jNMO5YLmud8U7iQ5gJK2zYyepeSuXhfSi8yjFZfRiSkelqSkU19I-Ja8aQBDbqXf2SAWA8mHF8VS3F08rgEaLCyv98fLLH4vSvsJGf6ueZSLKDVXz24rZRXGWtYYk_OYYTVgR1cg0BLCsuCvqZvHleImJKiWmtS0-CymMO4MMjCy_FIl6I56NqLE9C87tUVpo1mT-kbg5cHDD8I7MjCW5Iii5dethB4Vid3mZ6emKjVYgXrtkOQ-JyGMh6fnQxEFN1ft33GX2eRHluK9eg]];
				{     -- payload
					sub = "1234567890";
					name = "John Doe";
					admin = true;
					iat = 1516239022;
				};
			};
		};
	};

	local function do_verify_test(algorithm, verifying_key, token, expect_payload)
		local verify = jwt.new_verifier(algorithm, verifying_key);

		assert.is_string(token);
		local result = {verify(token)};
		if expect_payload then
			assert.same({
				true; -- success
				expect_payload; -- payload
			}, result);
		else
			assert.same({
				false;
				"signature-mismatch";
			}, result);
		end
	end

	local function do_sign_verify_test(algorithm, signing_key, verifying_key, expect_success, expect_token)
		local sign = jwt.new_signer(algorithm, signing_key);

		local test_payload = {
			sub = "1234567890";
			name = "John Doe";
			admin = true;
			iat = 1516239022;
		};

		local token = sign(test_payload);

		if expect_token then
			assert.equal(expect_token, token);
		end

		do_verify_test(algorithm, verifying_key, token, expect_success and test_payload or false);
	end
				


	for _, algorithm_tests in ipairs(test_cases) do
		local algorithm = algorithm_tests.algorithm;
		local keypairs = algorithm_tests.keys;
		describe(algorithm, function ()
			it("can do basic sign and verify", function ()
				for _, keypair in ipairs(keypairs) do
					local signing_key, verifying_key = keypair[1], keypair[2];
					do_sign_verify_test(algorithm, keypair[1], keypair[2], true);
				end
			end);

			if #keypairs >= 2 then
				it("rejects invalid tokens", function ()
					do_sign_verify_test(algorithm, keypairs[1][1], keypairs[2][2], false);
				end);
			else
				pending("rejects invalid tokens", function ()
					error("Needs at least 2 key pairs");
				end);
			end

			if #algorithm_tests > 0 then
				for test_n, test_case in ipairs(algorithm_tests) do
					it("can verify "..(test_case.name or (("test case %d"):format(test_n))), function ()
						do_verify_test(
							algorithm,
							test_case.verifying_key or keypairs[1][2],
							test_case[1],
							test_case[2]
						);
					end);
				end
			else
				pending("can verify reference tokens", function ()
					error("No test tokens provided");
				end);
			end
		end);
	end
end);

