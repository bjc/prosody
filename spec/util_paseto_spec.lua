-- Ignore long lines in this file
--luacheck: ignore 631

describe("util.paseto", function ()
	local paseto = require "util.paseto";
	local json = require "util.json";
	local hex = require "util.hex";

	describe("v3.local", function ()
		local function parse_test_cases(json_test_cases)
			local input_cases = json.decode(json_test_cases);
			local output_cases = {};
			for _, case in ipairs(input_cases) do
				assert.is_string(case.name, "Bad test case: expected name");
				assert.is_nil(output_cases[case.name], "Bad test case: duplicate name");
				output_cases[case.name] = function ()
					local key = hex.decode(case.key);
					local payload, err = paseto.v3_local.decrypt(case.token, key, case.footer, case["implicit-assertion"]);
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

		local test_cases = parse_test_cases [=[[
			    {
			      "name": "3-E-1",
			      "expect-fail": false,
			      "key": "707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f",
			      "nonce": "0000000000000000000000000000000000000000000000000000000000000000",
			      "token": "v3.local.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADbfcIURX_0pVZVU1mAESUzrKZAsRm2EsD6yBoZYn6cpVZNzSJOhSDN-sRaWjfLU-yn9OJH1J_B8GKtOQ9gSQlb8yk9Iza7teRdkiR89ZFyvPPsVjjFiepFUVcMa-LP18zV77f_crJrVXWa5PDNRkCSeHfBBeg",
			      "payload": "{\"data\":\"this is a secret message\",\"exp\":\"2022-01-01T00:00:00+00:00\"}",
			      "footer": "",
			      "implicit-assertion": ""
			    },
			    {
			      "name": "3-E-2",
			      "expect-fail": false,
			      "key": "707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f",
			      "nonce": "0000000000000000000000000000000000000000000000000000000000000000",
			      "token": "v3.local.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADbfcIURX_0pVZVU1mAESUzrKZAqhWxBMDgyBoZYn6cpVZNzSJOhSDN-sRaWjfLU-yn9OJH1J_B8GKtOQ9gSQlb8yk9IzZfaZpReVpHlDSwfuygx1riVXYVs-UjcrG_apl9oz3jCVmmJbRuKn5ZfD8mHz2db0A",
			      "payload": "{\"data\":\"this is a hidden message\",\"exp\":\"2022-01-01T00:00:00+00:00\"}",
			      "footer": "",
			      "implicit-assertion": ""
			    },
			    {
			      "name": "3-E-3",
			      "expect-fail": false,
			      "nonce": "26f7553354482a1d91d4784627854b8da6b8042a7966523c2b404e8dbbe7f7f2",
			      "key": "707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f",
			      "token": "v3.local.JvdVM1RIKh2R1HhGJ4VLjaa4BCp5ZlI8K0BOjbvn9_LwY78vQnDait-Q-sjhF88dG2B0ROIIykcrGHn8wzPbTrqObHhyoKpjy3cwZQzLdiwRsdEK5SDvl02_HjWKJW2oqGMOQJlxnt5xyhQjFJomwnt7WW_7r2VT0G704ifult011-TgLCyQ2X8imQhniG_hAQ4BydM",
			      "payload": "{\"data\":\"this is a secret message\",\"exp\":\"2022-01-01T00:00:00+00:00\"}",
			      "footer": "",
			      "implicit-assertion": ""
			    },
			    {
			      "name": "3-E-4",
			      "expect-fail": false,
			      "nonce": "26f7553354482a1d91d4784627854b8da6b8042a7966523c2b404e8dbbe7f7f2",
			      "key": "707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f",
			      "token": "v3.local.JvdVM1RIKh2R1HhGJ4VLjaa4BCp5ZlI8K0BOjbvn9_LwY78vQnDait-Q-sjhF88dG2B0X-4P3EcxGHn8wzPbTrqObHhyoKpjy3cwZQzLdiwRsdEK5SDvl02_HjWKJW2oqGMOQJlBZa_gOpVj4gv0M9lV6Pwjp8JS_MmaZaTA1LLTULXybOBZ2S4xMbYqYmDRhh3IgEk",
			      "payload": "{\"data\":\"this is a hidden message\",\"exp\":\"2022-01-01T00:00:00+00:00\"}",
			      "footer": "",
			      "implicit-assertion": ""
			    },
			    {
			      "name": "3-E-5",
			      "expect-fail": false,
			      "nonce": "26f7553354482a1d91d4784627854b8da6b8042a7966523c2b404e8dbbe7f7f2",
			      "key": "707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f",
			      "token": "v3.local.JvdVM1RIKh2R1HhGJ4VLjaa4BCp5ZlI8K0BOjbvn9_LwY78vQnDait-Q-sjhF88dG2B0ROIIykcrGHn8wzPbTrqObHhyoKpjy3cwZQzLdiwRsdEK5SDvl02_HjWKJW2oqGMOQJlkYSIbXOgVuIQL65UMdW9WcjOpmqvjqD40NNzed-XPqn1T3w-bJvitYpUJL_rmihc.eyJraWQiOiJVYmtLOFk2aXY0R1poRnA2VHgzSVdMV0xmTlhTRXZKY2RUM3pkUjY1WVp4byJ9",
			      "payload": "{\"data\":\"this is a secret message\",\"exp\":\"2022-01-01T00:00:00+00:00\"}",
			      "footer": "{\"kid\":\"UbkK8Y6iv4GZhFp6Tx3IWLWLfNXSEvJcdT3zdR65YZxo\"}",
			      "implicit-assertion": ""
			    },
			    {
			      "name": "3-E-6",
			      "expect-fail": false,
			      "nonce": "26f7553354482a1d91d4784627854b8da6b8042a7966523c2b404e8dbbe7f7f2",
			      "key": "707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f",
			      "token": "v3.local.JvdVM1RIKh2R1HhGJ4VLjaa4BCp5ZlI8K0BOjbvn9_LwY78vQnDait-Q-sjhF88dG2B0X-4P3EcxGHn8wzPbTrqObHhyoKpjy3cwZQzLdiwRsdEK5SDvl02_HjWKJW2oqGMOQJmSeEMphEWHiwtDKJftg41O1F8Hat-8kQ82ZIAMFqkx9q5VkWlxZke9ZzMBbb3Znfo.eyJraWQiOiJVYmtLOFk2aXY0R1poRnA2VHgzSVdMV0xmTlhTRXZKY2RUM3pkUjY1WVp4byJ9",
			      "payload": "{\"data\":\"this is a hidden message\",\"exp\":\"2022-01-01T00:00:00+00:00\"}",
			      "footer": "{\"kid\":\"UbkK8Y6iv4GZhFp6Tx3IWLWLfNXSEvJcdT3zdR65YZxo\"}",
			      "implicit-assertion": ""
			    },
			    {
			      "name": "3-E-7",
			      "expect-fail": false,
			      "nonce": "26f7553354482a1d91d4784627854b8da6b8042a7966523c2b404e8dbbe7f7f2",
			      "key": "707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f",
			      "token": "v3.local.JvdVM1RIKh2R1HhGJ4VLjaa4BCp5ZlI8K0BOjbvn9_LwY78vQnDait-Q-sjhF88dG2B0ROIIykcrGHn8wzPbTrqObHhyoKpjy3cwZQzLdiwRsdEK5SDvl02_HjWKJW2oqGMOQJkzWACWAIoVa0bz7EWSBoTEnS8MvGBYHHo6t6mJunPrFR9JKXFCc0obwz5N-pxFLOc.eyJraWQiOiJVYmtLOFk2aXY0R1poRnA2VHgzSVdMV0xmTlhTRXZKY2RUM3pkUjY1WVp4byJ9",
			      "payload": "{\"data\":\"this is a secret message\",\"exp\":\"2022-01-01T00:00:00+00:00\"}",
			      "footer": "{\"kid\":\"UbkK8Y6iv4GZhFp6Tx3IWLWLfNXSEvJcdT3zdR65YZxo\"}",
			      "implicit-assertion": "{\"test-vector\":\"3-E-7\"}"
			    },
			    {
			      "name": "3-E-8",
			      "expect-fail": false,
			      "nonce": "26f7553354482a1d91d4784627854b8da6b8042a7966523c2b404e8dbbe7f7f2",
			      "key": "707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f",
			      "token": "v3.local.JvdVM1RIKh2R1HhGJ4VLjaa4BCp5ZlI8K0BOjbvn9_LwY78vQnDait-Q-sjhF88dG2B0X-4P3EcxGHn8wzPbTrqObHhyoKpjy3cwZQzLdiwRsdEK5SDvl02_HjWKJW2oqGMOQJmZHSSKYR6AnPYJV6gpHtx6dLakIG_AOPhu8vKexNyrv5_1qoom6_NaPGecoiz6fR8.eyJraWQiOiJVYmtLOFk2aXY0R1poRnA2VHgzSVdMV0xmTlhTRXZKY2RUM3pkUjY1WVp4byJ9",
			      "payload": "{\"data\":\"this is a hidden message\",\"exp\":\"2022-01-01T00:00:00+00:00\"}",
			      "footer": "{\"kid\":\"UbkK8Y6iv4GZhFp6Tx3IWLWLfNXSEvJcdT3zdR65YZxo\"}",
			      "implicit-assertion": "{\"test-vector\":\"3-E-8\"}"
			    },
			    {
			      "name": "3-E-9",
			      "expect-fail": false,
			      "nonce": "26f7553354482a1d91d4784627854b8da6b8042a7966523c2b404e8dbbe7f7f2",
			      "key": "707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f",
			      "token": "v3.local.JvdVM1RIKh2R1HhGJ4VLjaa4BCp5ZlI8K0BOjbvn9_LwY78vQnDait-Q-sjhF88dG2B0X-4P3EcxGHn8wzPbTrqObHhyoKpjy3cwZQzLdiwRsdEK5SDvl02_HjWKJW2oqGMOQJlk1nli0_wijTH_vCuRwckEDc82QWK8-lG2fT9wQF271sgbVRVPjm0LwMQZkvvamqU.YXJiaXRyYXJ5LXN0cmluZy10aGF0LWlzbid0LWpzb24",
			      "payload": "{\"data\":\"this is a hidden message\",\"exp\":\"2022-01-01T00:00:00+00:00\"}",
			      "footer": "arbitrary-string-that-isn't-json",
			      "implicit-assertion": "{\"test-vector\":\"3-E-9\"}"
			    },
			    {
			      "name": "3-F-3",
			      "expect-fail": true,
			      "nonce": "26f7553354482a1d91d4784627854b8da6b8042a7966523c2b404e8dbbe7f7f2",
			      "key": "707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f",
			      "token": "v4.local.1JgN1UG8TFAYS49qsx8rxlwh-9E4ONUm3slJXYi5EibmzxpF0Q-du6gakjuyKCBX8TvnSLOKqCPu8Yh3WSa5yJWigPy33z9XZTJF2HQ9wlLDPtVn_Mu1pPxkTU50ZaBKblJBufRA.YXJiaXRyYXJ5LXN0cmluZy10aGF0LWlzbid0LWpzb24",
			      "payload": null,
			      "footer": "arbitrary-string-that-isn't-json",
			      "implicit-assertion": "{\"test-vector\":\"3-F-3\"}"
			    },
			    {
			      "name": "3-F-4",
			      "expect-fail": true,
			      "key": "707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f",
			      "nonce": "0000000000000000000000000000000000000000000000000000000000000000",
			      "token": "v3.local.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADbfcIURX_0pVZVU1mAESUzrKZAsRm2EsD6yBoZYn6cpVZNzSJOhSDN-sRaWjfLU-yn9OJH1J_B8GKtOQ9gSQlb8yk9Iza7teRdkiR89ZFyvPPsVjjFiepFUVcMa-LP18zV77f_crJrVXWa5PDNRkCSeHfBBeh",
			      "payload": null,
			      "footer": "",
			      "implicit-assertion": ""
			    },
			    {
			      "name": "3-F-5",
			      "expect-fail": true,
			      "nonce": "26f7553354482a1d91d4784627854b8da6b8042a7966523c2b404e8dbbe7f7f2",
			      "key": "707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f",
			      "token": "v3.local.JvdVM1RIKh2R1HhGJ4VLjaa4BCp5ZlI8K0BOjbvn9_LwY78vQnDait-Q-sjhF88dG2B0ROIIykcrGHn8wzPbTrqObHhyoKpjy3cwZQzLdiwRsdEK5SDvl02_HjWKJW2oqGMOQJlkYSIbXOgVuIQL65UMdW9WcjOpmqvjqD40NNzed-XPqn1T3w-bJvitYpUJL_rmihc=.eyJraWQiOiJVYmtLOFk2aXY0R1poRnA2VHgzSVdMV0xmTlhTRXZKY2RUM3pkUjY1WVp4byJ9",
			      "payload": null,
			      "footer": "{\"kid\":\"UbkK8Y6iv4GZhFp6Tx3IWLWLfNXSEvJcdT3zdR65YZxo\"}",
			      "implicit-assertion": ""
			}
			]]=];
		for name, test in pairs(test_cases) do
			it("test case "..name, test);
		end

		describe("basic sign/verify", function ()
			local key = paseto.v3_local.new_key();
			local sign, verify = paseto.v3_local.init(key);

			local key2 = paseto.v3_local.new_key();
			local sign2, verify2 = paseto.v3_local.init(key2);

			it("works", function ()
				local payload = { foo = "hello world", b = { 1, 2, 3 } };

				local tok = sign(payload);
				assert.same(payload, verify(tok));
				assert.is_nil(verify2(tok));
			end);

			it("rejects tokens if implicit assertion fails", function ()
				local payload = { foo = "hello world", b = { 1, 2, 3 } };
				local tok = sign(payload, nil, "my-custom-assertion");
				assert.is_nil(verify(tok, nil, "my-incorrect-assertion"));
				assert.is_nil(verify(tok, nil, nil));
				assert.same(payload, verify(tok, nil, "my-custom-assertion"));
			end);
		end);
	end);

	describe("v4.public", function ()
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
