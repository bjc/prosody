local record lib
	record key
		private_pem : function (key) : string
		public_pem : function (key) : string
		public_raw : function (key) : string
		get_type : function (key) : string
		derive : function (key, key) : string
	end

	type base_evp_sign = function (key, message : string) : string
	type base_evp_verify = function (key, message : string, signature : string) : boolean

	ed25519_sign : base_evp_sign
	ed25519_verify : base_evp_verify

	ecdsa_sha256_sign : base_evp_sign
	ecdsa_sha256_verify : base_evp_verify
	ecdsa_sha384_sign : base_evp_sign
	ecdsa_sha384_verify : base_evp_verify
	ecdsa_sha512_sign : base_evp_sign
	ecdsa_sha512_verify : base_evp_verify

	rsassa_pkcs1_sha256_sign : base_evp_sign
	rsassa_pkcs1_sha256_verify : base_evp_verify
	rsassa_pkcs1_sha384_sign : base_evp_sign
	rsassa_pkcs1_sha384_verify : base_evp_verify
	rsassa_pkcs1_sha512_sign : base_evp_sign
	rsassa_pkcs1_sha512_verify : base_evp_verify

	rsassa_pss_sha256_sign : base_evp_sign
	rsassa_pss_sha256_verify : base_evp_verify
	rsassa_pss_sha384_sign : base_evp_sign
	rsassa_pss_sha384_verify : base_evp_verify
	rsassa_pss_sha512_sign : base_evp_sign
	rsassa_pss_sha512_verify : base_evp_verify

	type Levp_encrypt = function (key : string, iv : string, plaintext : string) : string
	type Levp_decrypt = function (key : string, iv : string, ciphertext : string) : string, string

	aes_128_gcm_encrypt : Levp_encrypt
	aes_128_gcm_decrypt : Levp_decrypt
	aes_256_gcm_encrypt : Levp_encrypt
	aes_256_gcm_decrypt : Levp_decrypt

	aes_256_ctr_encrypt : Levp_encrypt
	aes_256_ctr_decrypt : Levp_decrypt

	generate_ed25519_keypair : function () : key
	generate_p256_keypair : function () : key

	import_private_pem : function (string) : key
	import_public_pem : function (string) : key
	import_public_ec_raw : function (string, string) : key

	parse_ecdsa_signature : function (string, integer) : string, string
	build_ecdsa_signature : function (r : string, s : string) : string

	version : string
	_LIBCRYPTO_VERSION : string
end
return lib
