local record lib
	record key
		private_pem : function (key) : string
		public_pem : function (key) : string
		get_type : function (key) : string
	end

	generate_ed25519_keypair : function () : key
	ed25519_sign : function (key, string) : string
	ed25519_verify : function (key, string, string) : boolean

	ecdsa_sha256_sign : function (key, string) : string
	ecdsa_sha256_verify : function (key, string, string) : boolean
	parse_ecdsa_signature : function (string) : string, string
	build_ecdsa_signature : function (string, string) : string

	import_private_pem : function (string) : key
	import_public_pem : function (string) : key

	aes_128_gcm_encrypt : function (key, string, string) : string
	aes_128_gcm_decrypt : function (key, string, string) : string
	aes_256_gcm_encrypt : function (key, string, string) : string
	aes_256_gcm_decrypt : function (key, string, string) : string


	version : string
	_LIBCRYPTO_VERSION : string
end
return lib
