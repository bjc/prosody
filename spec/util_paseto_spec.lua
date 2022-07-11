-- Ignore long lines in this file
--luacheck: ignore 631

describe("util.paseto", function ()
	local paseto = require "util.paseto";
	local json = require "util.json";

	local function parse_test_cases(json_test_cases)
		local input_cases = json.decode(json_test_cases);
		local output_cases = {};
		for _, case in ipairs(input_cases) do
			assert.is_string(case.name, "Bad test case: expected name");
			assert.is_nil(output_cases[case.name], "Bad test case: duplicate name");
			output_cases[case.name] = function ()
				local verify_key = paseto.v4_public.import_public_key(case["public-key-pem"]);
				local payload, err = paseto.v4_public.verify(case.token, verify_key, case.footer, case["implicit-assertion"]);
				if case["expect-fail"] then
					assert.is_nil(payload);
				else
					assert.is_nil(err);
					assert.same(json.decode(case.payload), payload);
				end
			end;
		end
		return output_cases;
	end

	describe("v4.public", function ()
		local test_cases = parse_test_cases [=[[
			{
			"name": "4-S-1",
			"expect-fail": false,
			"public-key": "1eb9dbbbbc047c03fd70604e0071f0987e16b28b757225c11f00415d0e20b1a2",
			"secret-key": "b4cbfb43df4ce210727d953e4a713307fa19bb7d9f85041438d9e11b942a37741eb9dbbbbc047c03fd70604e0071f0987e16b28b757225c11f00415d0e20b1a2",
			"secret-key-seed": "b4cbfb43df4ce210727d953e4a713307fa19bb7d9f85041438d9e11b942a3774",
			"secret-key-pem": "-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEILTL+0PfTOIQcn2VPkpxMwf6Gbt9n4UEFDjZ4RuUKjd0\n-----END PRIVATE KEY-----",
			"public-key-pem": "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAHrnbu7wEfAP9cGBOAHHwmH4Wsot1ciXBHwBBXQ4gsaI=\n-----END PUBLIC KEY-----",
			"token": "v4.public.eyJkYXRhIjoidGhpcyBpcyBhIHNpZ25lZCBtZXNzYWdlIiwiZXhwIjoiMjAyMi0wMS0wMVQwMDowMDowMCswMDowMCJ9bg_XBBzds8lTZShVlwwKSgeKpLT3yukTw6JUz3W4h_ExsQV-P0V54zemZDcAxFaSeef1QlXEFtkqxT1ciiQEDA",
			"payload": "{\"data\":\"this is a signed message\",\"exp\":\"2022-01-01T00:00:00+00:00\"}",
			"footer": "",
			"implicit-assertion": ""
			},
			{
			"name": "4-S-2",
			"expect-fail": false,
			"public-key": "1eb9dbbbbc047c03fd70604e0071f0987e16b28b757225c11f00415d0e20b1a2",
			"secret-key": "b4cbfb43df4ce210727d953e4a713307fa19bb7d9f85041438d9e11b942a37741eb9dbbbbc047c03fd70604e0071f0987e16b28b757225c11f00415d0e20b1a2",
			"secret-key-seed": "b4cbfb43df4ce210727d953e4a713307fa19bb7d9f85041438d9e11b942a3774",
			"secret-key-pem": "-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEILTL+0PfTOIQcn2VPkpxMwf6Gbt9n4UEFDjZ4RuUKjd0\n-----END PRIVATE KEY-----",
			"public-key-pem": "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAHrnbu7wEfAP9cGBOAHHwmH4Wsot1ciXBHwBBXQ4gsaI=\n-----END PUBLIC KEY-----",
			"token": "v4.public.eyJkYXRhIjoidGhpcyBpcyBhIHNpZ25lZCBtZXNzYWdlIiwiZXhwIjoiMjAyMi0wMS0wMVQwMDowMDowMCswMDowMCJ9v3Jt8mx_TdM2ceTGoqwrh4yDFn0XsHvvV_D0DtwQxVrJEBMl0F2caAdgnpKlt4p7xBnx1HcO-SPo8FPp214HDw.eyJraWQiOiJ6VmhNaVBCUDlmUmYyc25FY1Q3Z0ZUaW9lQTlDT2NOeTlEZmdMMVc2MGhhTiJ9",
			"payload": "{\"data\":\"this is a signed message\",\"exp\":\"2022-01-01T00:00:00+00:00\"}",
			"footer": "{\"kid\":\"zVhMiPBP9fRf2snEcT7gFTioeA9COcNy9DfgL1W60haN\"}",
			"implicit-assertion": ""
			},
			{
			"name": "4-S-3",
			"expect-fail": false,
			"public-key": "1eb9dbbbbc047c03fd70604e0071f0987e16b28b757225c11f00415d0e20b1a2",
			"secret-key": "b4cbfb43df4ce210727d953e4a713307fa19bb7d9f85041438d9e11b942a37741eb9dbbbbc047c03fd70604e0071f0987e16b28b757225c11f00415d0e20b1a2",
			"secret-key-seed": "b4cbfb43df4ce210727d953e4a713307fa19bb7d9f85041438d9e11b942a3774",
			"secret-key-pem": "-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEILTL+0PfTOIQcn2VPkpxMwf6Gbt9n4UEFDjZ4RuUKjd0\n-----END PRIVATE KEY-----",
			"public-key-pem": "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAHrnbu7wEfAP9cGBOAHHwmH4Wsot1ciXBHwBBXQ4gsaI=\n-----END PUBLIC KEY-----",
			"token": "v4.public.eyJkYXRhIjoidGhpcyBpcyBhIHNpZ25lZCBtZXNzYWdlIiwiZXhwIjoiMjAyMi0wMS0wMVQwMDowMDowMCswMDowMCJ9NPWciuD3d0o5eXJXG5pJy-DiVEoyPYWs1YSTwWHNJq6DZD3je5gf-0M4JR9ipdUSJbIovzmBECeaWmaqcaP0DQ.eyJraWQiOiJ6VmhNaVBCUDlmUmYyc25FY1Q3Z0ZUaW9lQTlDT2NOeTlEZmdMMVc2MGhhTiJ9",
			"payload": "{\"data\":\"this is a signed message\",\"exp\":\"2022-01-01T00:00:00+00:00\"}",
			"footer": "{\"kid\":\"zVhMiPBP9fRf2snEcT7gFTioeA9COcNy9DfgL1W60haN\"}",
			"implicit-assertion": "{\"test-vector\":\"4-S-3\"}"
			}]]=];
		for name, test in pairs(test_cases) do
			it("test case "..name, test);
		end

		describe("basic sign/verify", function ()
			local function new_keypair()
				local kp = paseto.v4_public.new_keypair();
				return kp:private_pem(), kp:public_pem();
			end

			local privkey1, pubkey1 = new_keypair();
			local privkey2, pubkey2 = new_keypair();
			local sign1, verify1 = paseto.v4_public.init(privkey1, pubkey1);
			local sign2, verify2 = paseto.v4_public.init(privkey2, pubkey2);

			it("works", function ()
				local payload = { foo = "hello world", b = { 1, 2, 3 } };

				local tok1 = sign1(payload);
				assert.same(payload, verify1(tok1));
				assert.is_nil(verify2(tok1));

				local tok2 = sign2(payload);
				assert.same(payload, verify2(tok2));
				assert.is_nil(verify1(tok2));
			end);

			it("rejects tokens if implicit assertion fails", function ()
				local payload = { foo = "hello world", b = { 1, 2, 3 } };
				local tok = sign1(payload, nil, "my-custom-assertion");
				assert.is_nil(verify1(tok, nil, "my-incorrect-assertion"));
				assert.is_nil(verify1(tok, nil, nil));
				assert.same(payload, verify1(tok, nil, "my-custom-assertion"));
			end);
		end);
	end);

	describe("pae", function ()
		it("encodes correctly", function ()
			-- These test cases are taken from the PASETO docs
			-- https://github.com/paseto-standard/paseto-spec/blob/master/docs/01-Protocol-Versions/Common.md
			assert.equal("\x00\x00\x00\x00\x00\x00\x00\x00", paseto.pae{});
			assert.equal("\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", paseto.pae{''});
			assert.equal("\x01\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00test", paseto.pae{'test'});
			assert.has_errors(function ()
				paseto.pae("test");
			end);
		end);
	end);
end);
