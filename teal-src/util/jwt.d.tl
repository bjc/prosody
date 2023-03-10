local record jwtlib
	enum algorithm
		"HS256"
		"HS384"
		"HS512"
		"ES256"
		"ES512"
		"RS256"
		"RS384"
		"RS512"
		"PS256"
		"PS384"
		"PS512"
	end
	type payload = { string : any }
	type signer_t = function (payload : payload) : string
	type verifier_t = function (token : string) : payload
	enum key_type
		"rsaEncryption"
		"id-ecPublicKey"
	end
	record key_t
		get_type : function (key_t) : key_type
	end
	record algorithm_t
		sign : signer_t
		verify : verifier_t
		load_key : function (key : string) : key_t
	end
	init : function (algorithm, private_key : string, public_key : string, table) : signer_t, verifier_t
	new_signer : function (algorithm, string, table) : signer_t
	new_verifier : function (algorithm, string, table) : verifier_t
	_algorithms : {
		algorithm : algorithm_t
	}
	-- Deprecated
	sign : function (private_key : string, payload) : string
	verify : function (string) : payload
end
return jwtlib
