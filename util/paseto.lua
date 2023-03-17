local crypto = require "prosody.util.crypto";
local json = require "prosody.util.json";
local hashes = require "prosody.util.hashes";
local base64_encode = require "prosody.util.encodings".base64.encode;
local base64_decode = require "prosody.util.encodings".base64.decode;
local secure_equals = require "prosody.util.hashes".equals;
local bit = require "prosody.util.bitcompat";
local hex = require "prosody.util.hex";
local rand = require "prosody.util.random";
local s_pack = require "prosody.util.struct".pack;

local s_gsub = string.gsub;

local v4_public = {};

local b64url_rep = { ["+"] = "-", ["/"] = "_", ["="] = "", ["-"] = "+", ["_"] = "/" };
local function b64url(data)
	return (s_gsub(base64_encode(data), "[+/=]", b64url_rep));
end

local valid_tails = {
	nil; -- Always invalid
	"^.[AQgw]$"; -- b??????00
	"^..[AQgwEUk0IYo4Mcs8]$"; -- b????0000
}

local function unb64url(data)
	local rem = #data%4;
	if data:sub(-1,-1) == "=" or rem == 1 or (rem > 1 and not data:sub(-rem):match(valid_tails[rem])) then
		return nil;
	end
	return base64_decode(s_gsub(data, "[-_]", b64url_rep).."==");
end

local function le64(n)
	return s_pack("<I8", bit.band(n, 0x7F));
end

local function pae(parts)
	if type(parts) ~= "table" then
		error("bad argument #1 to 'pae' (table expected, got "..type(parts)..")");
	end
	local o = { le64(#parts) };
	for _, part in ipairs(parts) do
		table.insert(o, le64(#part)..part);
	end
	return table.concat(o);
end

function v4_public.sign(m, sk, f, i)
	if type(m) ~= "table" then
		return nil, "PASETO payloads must be a table";
	end
	m = json.encode(m);
	local h = "v4.public.";
	local m2 = pae({ h, m, f or "", i or "" });
	local sig = crypto.ed25519_sign(sk, m2);
	if not f or f == "" then
		return h..b64url(m..sig);
	else
		return h..b64url(m..sig).."."..b64url(f);
	end
end

function v4_public.verify(tok, pk, expected_f, i)
	local h, sm, f = tok:match("^(v4%.public%.)([^%.]+)%.?(.*)$");
	if not h then
		return nil, "invalid-token-format";
	end
	f = f and unb64url(f) or nil;
	if expected_f then
		if not f or not secure_equals(expected_f, f) then
			return nil, "invalid-footer";
		end
	end
	local raw_sm = unb64url(sm);
	if not raw_sm or #raw_sm <= 64 then
		return nil, "invalid-token-format";
	end
	local s, m = raw_sm:sub(-64), raw_sm:sub(1, -65);
	local m2 = pae({ h, m, f or "", i or "" });
	local ok = crypto.ed25519_verify(pk, m2, s);
	if not ok then
		return nil, "invalid-token";
	end
	local payload, err = json.decode(m);
	if err ~= nil or type(payload) ~= "table" then
		return nil, "json-decode-error";
	end
	return payload;
end

v4_public.import_private_key = crypto.import_private_pem;
v4_public.import_public_key = crypto.import_public_pem;
function v4_public.new_keypair()
	return crypto.generate_ed25519_keypair();
end

function v4_public.init(private_key_pem, public_key_pem, options)
	local sign, verify = v4_public.sign, v4_public.verify;
	local public_key = public_key_pem and v4_public.import_public_key(public_key_pem);
	local private_key = private_key_pem and v4_public.import_private_key(private_key_pem);
	local default_footer = options and options.default_footer;
	local default_assertion = options and options.default_implicit_assertion;
	return private_key and function (token, token_footer, token_assertion)
		return sign(token, private_key, token_footer or default_footer, token_assertion or default_assertion);
	end, public_key and function (token, expected_footer, token_assertion)
		return verify(token, public_key, expected_footer or default_footer, token_assertion or default_assertion);
	end;
end

function v4_public.new_signer(private_key_pem, options)
	return (v4_public.init(private_key_pem, nil, options));
end

function v4_public.new_verifier(public_key_pem, options)
	return (select(2, v4_public.init(nil, public_key_pem, options)));
end

local v3_local = { _key_mt = {} };

local function v3_local_derive_keys(k, n)
	local tmp = hashes.hkdf_hmac_sha384(48, k, nil, "paseto-encryption-key"..n);
	local Ek = tmp:sub(1, 32);
	local n2 = tmp:sub(33);
	local Ak = hashes.hkdf_hmac_sha384(48, k, nil, "paseto-auth-key-for-aead"..n);
	return Ek, Ak, n2;
end

function v3_local.encrypt(m, k, f, i)
	assert(#k == 32)
	if type(m) ~= "table" then
		return nil, "PASETO payloads must be a table";
	end
	m = json.encode(m);
	local h = "v3.local.";
	local n = rand.bytes(32);
	local Ek, Ak, n2 = v3_local_derive_keys(k, n);

	local c = crypto.aes_256_ctr_encrypt(Ek, n2, m);
	local m2 = pae({ h, n, c, f or "", i or "" });
	local t = hashes.hmac_sha384(Ak, m2);

	if not f or f == "" then
		return h..b64url(n..c..t);
	else
		return h..b64url(n..c..t).."."..b64url(f);
	end
end

function v3_local.decrypt(tok, k, expected_f, i)
	assert(#k == 32)

	local h, sm, f = tok:match("^(v3%.local%.)([^%.]+)%.?(.*)$");
	if not h then
		return nil, "invalid-token-format";
	end
	f = f and unb64url(f) or nil;
	if expected_f then
		if not f or not secure_equals(expected_f, f) then
			return nil, "invalid-footer";
		end
	end
	local m = unb64url(sm);
	if not m or #m <= 80 then
		return nil, "invalid-token-format";
	end
	local n, c, t = m:sub(1, 32), m:sub(33, -49), m:sub(-48);
	local Ek, Ak, n2 = v3_local_derive_keys(k, n);
	local preAuth = pae({ h, n, c, f or "", i or "" });
	local t2 = hashes.hmac_sha384(Ak, preAuth);
	if not secure_equals(t, t2) then
		return nil, "invalid-token";
	end
	local m2 = crypto.aes_256_ctr_decrypt(Ek, n2, c);
	if not m2 then
		return nil, "invalid-token";
	end

	local payload, err = json.decode(m2);
	if err ~= nil or type(payload) ~= "table" then
		return nil, "json-decode-error";
	end
	return payload;
end

function v3_local.new_key()
	return "secret-token:paseto.v3.local:"..hex.encode(rand.bytes(32));
end

function v3_local.init(key, options)
	local encoded_key = key:match("^secret%-token:paseto%.v3%.local:(%x+)$");
	if not encoded_key or #encoded_key ~= 64 then
		return error("invalid key for v3.local");
	end
	local raw_key = hex.decode(encoded_key);
	local default_footer = options and options.default_footer;
	local default_assertion = options and options.default_implicit_assertion;
	return function (token, token_footer, token_assertion)
		return v3_local.encrypt(token, raw_key, token_footer or default_footer, token_assertion or default_assertion);
	end, function (token, token_footer, token_assertion)
		return v3_local.decrypt(token, raw_key, token_footer or default_footer, token_assertion or default_assertion);
	end;
end

function v3_local.new_signer(key, options)
	return (v3_local.init(key, options));
end

function v3_local.new_verifier(key, options)
	return (select(2, v3_local.init(key, options)));
end

return {
	pae = pae;
	v3_local = v3_local;
	v4_public = v4_public;
};
