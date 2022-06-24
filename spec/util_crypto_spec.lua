local test_keys = {
	ecdsa_private_pem = [[
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg7taVK6bPtPz4ah32
aD9CfvOah5omBxRVtzypwQXvZeahRANCAAQpKFeNIy27+lVo6bJslO6r2ty5rlb5
xEiCx8GrrbJ8S7b5IPZCS7OrBaO2iqgOf7NMsgO12eLCfMZRnA+gCC34
-----END PRIVATE KEY-----
]];

	ecdsa_public_pem = [[
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEKShXjSMtu/pVaOmybJTuq9rcua5W
+cRIgsfBq62yfEu2+SD2QkuzqwWjtoqoDn+zTLIDtdniwnzGUZwPoAgt+A==
-----END PUBLIC KEY-----
]];

	eddsa_private_pem = [[
-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VwBCIEIOmrajEfnqdzdJzkJ4irQMCGbYRqrl0RlwPHIw+a5b7M
-----END PRIVATE KEY-----
]];

	eddsa_public_pem = [[
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAFipbSXeGvPVK7eA4+hIOdutZTUUyXswVSbMGi0j1QKE=
-----END PUBLIC KEY-----
]];

};

describe("util.crypto", function ()
	local crypto = require "util.crypto";
	local random = require "util.random";

	describe("generate_ed25519_keypair", function ()
		local keypair = crypto.generate_ed25519_keypair();
		assert.is_not_nil(keypair);
		assert.equal("ED25519", keypair:get_type());
	end)

	describe("import_private_pem", function ()
		it("can import ECDSA keys", function ()
			local ecdsa_key = crypto.import_private_pem(test_keys.ecdsa_private_pem);
			assert.equal("id-ecPublicKey", ecdsa_key:get_type());
		end);

		it("can import EdDSA (Ed25519) keys", function ()
			local ed25519_key = crypto.import_private_pem(crypto.generate_ed25519_keypair():private_pem());
			assert.equal("ED25519", ed25519_key:get_type());
		end);

		it("can import RSA keys", function ()
			-- TODO
		end);

		it("rejects invalid keys", function ()
			assert.is_nil(crypto.import_private_pem(test_keys.eddsa_public_pem));
			assert.is_nil(crypto.import_private_pem(test_keys.ecdsa_public_pem));
			assert.is_nil(crypto.import_private_pem("foo"));
			assert.is_nil(crypto.import_private_pem(""));
		end);
	end);

	describe("import_public_pem", function ()
		it("can import ECDSA public keys", function ()
			local ecdsa_key = crypto.import_public_pem(test_keys.ecdsa_public_pem);
			assert.equal("id-ecPublicKey", ecdsa_key:get_type());
		end);

		it("can import EdDSA (Ed25519) public keys", function ()
			local ed25519_key = crypto.import_public_pem(test_keys.eddsa_public_pem);
			assert.equal("ED25519", ed25519_key:get_type());
		end);

		it("can import RSA public keys", function ()
			-- TODO
		end);
	end);

	describe("PEM export", function ()
		it("works", function ()
			local ecdsa_key = crypto.import_public_pem(test_keys.ecdsa_public_pem);
			assert.equal("id-ecPublicKey", ecdsa_key:get_type());
			assert.equal(test_keys.ecdsa_public_pem, ecdsa_key:public_pem());

			assert.has_error(function ()
				-- Fails because private key is not available
				ecdsa_key:private_pem();
			end);

			local ecdsa_private_key = crypto.import_private_pem(test_keys.ecdsa_private_pem);
			assert.equal(test_keys.ecdsa_private_pem, ecdsa_private_key:private_pem());
		end);
	end);

	describe("sign/verify with", function ()
		local test_cases = {
			ed25519 = {
				crypto.ed25519_sign, crypto.ed25519_verify;
				key = crypto.import_private_pem(test_keys.eddsa_private_pem);
				sig_length = 64;
			};
			ecdsa = {
				crypto.ecdsa_sha256_sign, crypto.ecdsa_sha256_verify;
				key = crypto.import_private_pem(test_keys.ecdsa_private_pem);
			};
		};
		for test_name, test in pairs(test_cases) do
			local key = test.key;
			describe(test_name, function ()
				it("works", function ()
					local sign, verify = test[1], test[2];
					local sig = assert(sign(key, "Hello world"));
					assert.is_string(sig);
					if test.sig_length then
						assert.equal(test.sig_length, #sig);
					end

					do
						local ok = verify(key, "Hello world", sig);
						assert.is_truthy(ok);
					end
					do -- Incorrect signature
						local ok = verify(key, "Hello world", sig:sub(1, -2)..string.char((sig:byte(-1)+1)%255));
						assert.is_falsy(ok);
					end
					do -- Incorrect message
						local ok = verify(key, "Hello earth", sig);
						assert.is_falsy(ok);
					end
					do -- Incorrect message (embedded NUL)
						local ok = verify(key, "Hello world\0foo", sig);
						assert.is_falsy(ok);
					end
				end);
			end);
		end
	end);

	describe("ECDSA signatures", function ()
		local hex = require "util.hex";
		local sig = hex.decode((([[
			304402203e936e7b0bc62887e0e9d675afd08531a930384cfcf301
			f25d13053a2ebf141d02205a5a7c7b7ac5878d004cb79b17b39346
			6b0cd1043718ffc31c153b971d213a8e
		]]):gsub("%s+", "")));
		it("can be parsed", function ()
			local r, s = crypto.parse_ecdsa_signature(sig);
			assert.is_string(r);
			assert.is_string(s);
			assert.equal(32, #r);
			assert.equal(32, #s);
		end);
		it("fails to parse invalid signatures", function ()
			local invalid_sigs = {
				"";
				"\000";
				string.rep("\000", 64);
				string.rep("\000", 72);
				string.rep("\000", 256);
				string.rep("\255", 72);
				string.rep("\255", 3);
			};
			for _, sig in ipairs(invalid_sigs) do
				local r, s = crypto.parse_ecdsa_signature("");
				assert.is_nil(r);
				assert.is_nil(s);
			end
			
		end);
		it("can be built", function ()
			local r, s = crypto.parse_ecdsa_signature(sig);
			local rebuilt_sig = crypto.build_ecdsa_signature(r, s);
			assert.equal(sig, rebuilt_sig);
		end);
	end);

	describe("AES-GCM encryption", function ()
		it("works", function ()
			local message = "foo\0bar";
			local key_128_bit = random.bytes(16);
			local key_256_bit = random.bytes(32);
			local test_cases = {
				{ crypto.aes_128_gcm_encrypt, crypto.aes_128_gcm_decrypt, key = key_128_bit };
				{ crypto.aes_256_gcm_encrypt, crypto.aes_256_gcm_decrypt, key = key_256_bit };
			};
			for _, params in pairs(test_cases) do
				local iv = params.iv or random.bytes(12);
				local encrypted = params[1](params.key, iv, message);
				assert.not_equal(message, encrypted);
				local decrypted = params[2](params.key, iv, encrypted);
				assert.equal(message, decrypted);
			end
		end);
	end);
end);
