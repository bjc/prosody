local jwt = require "util.jwt";
local test_keys = require "spec.inputs.test_keys";

local array = require "util.array";
local iter = require "util.iterators";
local set = require "util.set";

-- Ignore long lines. We have some long tokens embedded here.
--luacheck: ignore 631

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

	local function jwt_reference_token(token)
		return {
			name = "jwt.io reference";
			token;
			{     -- payload
				sub = "1234567890";
				name = "John Doe";
				admin = true;
				iat = 1516239022;
			};
		};
	end

	local untested_algorithms = set.new(array.collect(iter.keys(jwt._algorithms)));

	local test_cases = {
		{
			algorithm = "HS256";
			keys = {
				{ "your-256-bit-secret", "your-256-bit-secret" };
				{ "another-secret", "another-secret" };
			};

			jwt_reference_token [[eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyLCJhZG1pbiI6dHJ1ZX0.F-cvL2RcfQhUtCavIM7q7zYE8drmj2LJk0JRkrS6He4]];
		};
		{
			algorithm = "HS384";
			keys = {
				{ "your-384-bit-secret", "your-384-bit-secret" };
				{ "another-secret", "another-secret" };
			};

			jwt_reference_token [[eyJhbGciOiJIUzM4NCIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWUsImlhdCI6MTUxNjIzOTAyMn0.bQTnz6AuMJvmXXQsVPrxeQNvzDkimo7VNXxHeSBfClLufmCVZRUuyTwJF311JHuh]];
		};
		{
			algorithm = "HS512";
			keys = {
				{ "your-512-bit-secret", "your-512-bit-secret" };
				{ "another-secret", "another-secret" };
			};

			jwt_reference_token [[eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWUsImlhdCI6MTUxNjIzOTAyMn0.VFb0qJ1LRg_4ujbZoRMXnVkUgiuKq5KxWqNdbKq_G9Vvz-S1zZa9LPxtHWKa64zDl2ofkT8F6jBt_K4riU-fPg]];
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
			algorithm = "RS384";
			keys = {
				{ test_keys.rsa_private_pem, test_keys.rsa_public_pem };
				{ test_keys.alt_rsa_private_pem, test_keys.alt_rsa_public_pem };
			};

			jwt_reference_token [[eyJhbGciOiJSUzM4NCIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWUsImlhdCI6MTUxNjIzOTAyMn0.o1hC1xYbJolSyh0-bOY230w22zEQSk5TiBfc-OCvtpI2JtYlW-23-8B48NpATozzMHn0j3rE0xVUldxShzy0xeJ7vYAccVXu2Gs9rnTVqouc-UZu_wJHkZiKBL67j8_61L6SXswzPAQu4kVDwAefGf5hyYBUM-80vYZwWPEpLI8K4yCBsF6I9N1yQaZAJmkMp_Iw371Menae4Mp4JusvBJS-s6LrmG2QbiZaFaxVJiW8KlUkWyUCns8-qFl5OMeYlgGFsyvvSHvXCzQrsEXqyCdS4tQJd73ayYA4SPtCb9clz76N1zE5WsV4Z0BYrxeb77oA7jJhh994RAPzCG0hmQ]];
		};
		{
			algorithm = "RS512";
			keys = {
				{ test_keys.rsa_private_pem, test_keys.rsa_public_pem };
				{ test_keys.alt_rsa_private_pem, test_keys.alt_rsa_public_pem };
			};

			jwt_reference_token [[eyJhbGciOiJSUzUxMiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWUsImlhdCI6MTUxNjIzOTAyMn0.jYW04zLDHfR1v7xdrW3lCGZrMIsVe0vWCfVkN2DRns2c3MN-mcp_-RE6TN9umSBYoNV-mnb31wFf8iun3fB6aDS6m_OXAiURVEKrPFNGlR38JSHUtsFzqTOj-wFrJZN4RwvZnNGSMvK3wzzUriZqmiNLsG8lktlEn6KA4kYVaM61_NpmPHWAjGExWv7cjHYupcjMSmR8uMTwN5UuAwgW6FRstCJEfoxwb0WKiyoaSlDuIiHZJ0cyGhhEmmAPiCwtPAwGeaL1yZMcp0p82cpTQ5Qb-7CtRov3N4DcOHgWYk6LomPR5j5cCkePAz87duqyzSMpCB0mCOuE3CU2VMtGeQ]];
		};
		{
			algorithm = "PS256";
			keys = {
				{ test_keys.rsa_private_pem, test_keys.rsa_public_pem };
				{ test_keys.alt_rsa_private_pem, test_keys.alt_rsa_public_pem };
			};

			jwt_reference_token [[eyJhbGciOiJQUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWUsImlhdCI6MTUxNjIzOTAyMn0.iOeNU4dAFFeBwNj6qdhdvm-IvDQrTa6R22lQVJVuWJxorJfeQww5Nwsra0PjaOYhAMj9jNMO5YLmud8U7iQ5gJK2zYyepeSuXhfSi8yjFZfRiSkelqSkU19I-Ja8aQBDbqXf2SAWA8mHF8VS3F08rgEaLCyv98fLLH4vSvsJGf6ueZSLKDVXz24rZRXGWtYYk_OYYTVgR1cg0BLCsuCvqZvHleImJKiWmtS0-CymMO4MMjCy_FIl6I56NqLE9C87tUVpo1mT-kbg5cHDD8I7MjCW5Iii5dethB4Vid3mZ6emKjVYgXrtkOQ-JyGMh6fnQxEFN1ft33GX2eRHluK9eg]];
		};
		{
			algorithm = "PS384";
			keys = {
				{ test_keys.rsa_private_pem, test_keys.rsa_public_pem };
				{ test_keys.alt_rsa_private_pem, test_keys.alt_rsa_public_pem };
			};

			jwt_reference_token [[eyJhbGciOiJQUzM4NCIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWUsImlhdCI6MTUxNjIzOTAyMn0.Lfe_aCQme_gQpUk9-6l9qesu0QYZtfdzfy08w8uqqPH_gnw-IVyQwyGLBHPFBJHMbifdSMxPjJjkCD0laIclhnBhowILu6k66_5Y2z78GHg8YjKocAvB-wSUiBhuV6hXVxE5emSjhfVz2OwiCk2bfk2hziRpkdMvfcITkCx9dmxHU6qcEIsTTHuH020UcGayB1-IoimnjTdCsV1y4CMr_ECDjBrqMdnontkqKRIM1dtmgYFsJM6xm7ewi_ksG_qZHhaoBkxQ9wq9OVQRGiSZYowCp73d2BF3jYMhdmv2JiaUz5jRvv6lVU7Quq6ylVAlSPxeov9voYHO1mgZFCY1kQ]];
		};
		{
			algorithm = "PS512";
			keys = {
				{ test_keys.rsa_private_pem, test_keys.rsa_public_pem };
				{ test_keys.alt_rsa_private_pem, test_keys.alt_rsa_public_pem };
			};

			jwt_reference_token [[eyJhbGciOiJQUzUxMiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiYWRtaW4iOnRydWUsImlhdCI6MTUxNjIzOTAyMn0.J5W09-rNx0pt5_HBiydR-vOluS6oD-RpYNa8PVWwMcBDQSXiw6-EPW8iSsalXPspGj3ouQjAnOP_4-zrlUUlvUIt2T79XyNeiKuooyIFvka3Y5NnGiOUBHWvWcWp4RcQFMBrZkHtJM23sB5D7Wxjx0-HFeNk-Y3UJgeJVhg5NaWXypLkC4y0ADrUBfGAxhvGdRdULZivfvzuVtv6AzW6NRuEE6DM9xpoWX_4here-yvLS2YPiBTZ8xbB3axdM99LhES-n52lVkiX5AWg2JJkEROZzLMpaacA_xlbUz_zbIaOaoqk8gB5oO7kI6sZej3QAdGigQy-hXiRnW_L98d4GQ]];
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

		untested_algorithms:remove(algorithm);

		describe(algorithm, function ()
			it("can do basic sign and verify", function ()
				for _, keypair in ipairs(keypairs) do
					local signing_key, verifying_key = keypair[1], keypair[2];
					do_sign_verify_test(algorithm, signing_key, verifying_key, true);
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

	for algorithm in untested_algorithms do
		pending(algorithm.." tests", function () end);
	end
end);

