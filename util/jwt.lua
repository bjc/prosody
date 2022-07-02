local s_gsub = string.gsub;
local crypto = require "util.crypto";
local json = require "util.json";
local hashes = require "util.hashes";
local base64_encode = require "util.encodings".base64.encode;
local base64_decode = require "util.encodings".base64.decode;
local secure_equals = require "util.hashes".equals;

local b64url_rep = { ["+"] = "-", ["/"] = "_", ["="] = "", ["-"] = "+", ["_"] = "/" };
local function b64url(data)
	return (s_gsub(base64_encode(data), "[+/=]", b64url_rep));
end
local function unb64url(data)
	return base64_decode(s_gsub(data, "[-_]", b64url_rep).."==");
end

local jwt_pattern = "^(([A-Za-z0-9-_]+)%.([A-Za-z0-9-_]+))%.([A-Za-z0-9-_]+)$"
local function decode_jwt(blob, expected_alg)
	local signed, bheader, bpayload, signature = string.match(blob, jwt_pattern);
	if not signed then
		return nil, "invalid-encoding";
	end
	local header = json.decode(unb64url(bheader));
	if not header or type(header) ~= "table" then
		return nil, "invalid-header";
	elseif header.alg ~= expected_alg then
		return nil, "unsupported-algorithm";
	end
	return signed, signature, bpayload;
end

local function new_static_header(algorithm_name)
	return b64url('{"alg":"'..algorithm_name..'","typ":"JWT"}') .. '.';
end

-- HS*** family
local function new_hmac_algorithm(name)
	local static_header = new_static_header(name);

	local hmac = hashes["hmac_sha"..name:sub(-3)];

	local function sign(key, payload)
		local encoded_payload = json.encode(payload);
		local signed = static_header .. b64url(encoded_payload);
		local signature = hmac(key, signed);
		return signed .. "." .. b64url(signature);
	end

	local function verify(key, blob)
		local signed, signature, raw_payload = decode_jwt(blob, name);
		if not signed then return nil, signature; end -- nil, err

		if not secure_equals(b64url(hmac(key, signed)), signature) then
			return false, "signature-mismatch";
		end
		local payload, err = json.decode(unb64url(raw_payload));
		if err ~= nil then
			return nil, "json-decode-error";
		end
		return true, payload;
	end

	local function load_key(key)
		assert(type(key) == "string", "key must be string (long, random, secure)");
		return key;
	end

	return { sign = sign, verify = verify, load_key = load_key };
end

local function new_crypto_algorithm(name, key_type, c_sign, c_verify, sig_encode, sig_decode)
	local static_header = new_static_header(name);

	return {
		sign = function (private_key, payload)
			local encoded_payload = json.encode(payload);
			local signed = static_header .. b64url(encoded_payload);

			local signature = c_sign(private_key, signed);
			if sig_encode then
				signature = sig_encode(signature);
			end

			return signed.."."..b64url(signature);
		end;

		verify = function (public_key, blob)
			local signed, signature, raw_payload = decode_jwt(blob, name);
			if not signed then return nil, signature; end -- nil, err

			signature = unb64url(signature);
			if sig_decode and signature then
				signature = sig_decode(signature);
			end
			if not signature then
				return false, "signature-mismatch";
			end

			local verify_ok = c_verify(public_key, signed, signature);
			if not verify_ok then
				return false, "signature-mismatch";
			end

			local payload, err = json.decode(unb64url(raw_payload));
			if err ~= nil then
				return nil, "json-decode-error";
			end

			return true, payload;
		end;

		load_public_key = function (public_key_pem)
			local key = assert(crypto.import_public_pem(public_key_pem));
			assert(key:get_type() == key_type, "incorrect key type");
			return key;
		end;

		load_private_key = function (private_key_pem)
			local key = assert(crypto.import_private_pem(private_key_pem));
			assert(key:get_type() == key_type, "incorrect key type");
			return key;
		end;
	};
end

-- RS***, PS***
local rsa_sign_algos = { RS = "rsassa_pkcs1", PS = "rsassa_pss" };
local function new_rsa_algorithm(name)
	local family, digest_bits = name:match("^(..)(...)$");
	local c_sign = crypto[rsa_sign_algos[family].."_sha"..digest_bits.."_sign"];
	local c_verify = crypto[rsa_sign_algos[family].."_sha"..digest_bits.."_verify"];
	return new_crypto_algorithm(name, "rsaEncryption", c_sign, c_verify);
end

-- ES***
local function new_ecdsa_algorithm(name, c_sign, c_verify)
	local function encode_ecdsa_sig(der_sig)
		local r, s = crypto.parse_ecdsa_signature(der_sig);
		return r..s;
	end

	local function decode_ecdsa_sig(jwk_sig)
		return crypto.build_ecdsa_signature(jwk_sig:sub(1, 32), jwk_sig:sub(33, 64));
	end
	return new_crypto_algorithm(name, "id-ecPublicKey", c_sign, c_verify, encode_ecdsa_sig, decode_ecdsa_sig);
end

local algorithms = {
	HS256 = new_hmac_algorithm("HS256"), HS384 = new_hmac_algorithm("HS384"), HS512 = new_hmac_algorithm("HS512");
	ES256 = new_ecdsa_algorithm("ES256", crypto.ecdsa_sha256_sign, crypto.ecdsa_sha256_verify);
	RS256 = new_rsa_algorithm("RS256"), RS384 = new_rsa_algorithm("RS384"), RS512 = new_rsa_algorithm("RS512");
	PS256 = new_rsa_algorithm("PS256"), PS384 = new_rsa_algorithm("PS384"), PS512 = new_rsa_algorithm("PS512");
};

local function new_signer(algorithm, key_input)
	local impl = assert(algorithms[algorithm], "Unknown JWT algorithm: "..algorithm);
	local key = (impl.load_private_key or impl.load_key)(key_input);
	local sign = impl.sign;
	return function (payload)
		return sign(key, payload);
	end
end

local function new_verifier(algorithm, key_input)
	local impl = assert(algorithms[algorithm], "Unknown JWT algorithm: "..algorithm);
	local key = (impl.load_public_key or impl.load_key)(key_input);
	local verify = impl.verify;
	return function (token)
		return verify(key, token);
	end
end

return {
	new_signer = new_signer;
	new_verifier = new_verifier;
	_algorithms = algorithms;
	-- Deprecated
	sign = algorithms.HS256.sign;
	verify = algorithms.HS256.verify;
};

