local crypto = require "util.crypto";
local json = require "util.json";
local base64_encode = require "util.encodings".base64.encode;
local base64_decode = require "util.encodings".base64.decode;
local secure_equals = require "util.hashes".equals;
local bit = require "util.bitcompat";
local s_pack = require "util.struct".pack;

local s_gsub = string.gsub;

local pubkey_methods = {};
local privkey_methods = {};

local v4_public_pubkey_mt = { __index = pubkey_methods };
local v4_public_privkey_mt = { __index = privkey_methods };
local v4_public = {};

local b64url_rep = { ["+"] = "-", ["/"] = "_", ["="] = "", ["-"] = "+", ["_"] = "/" };
local function b64url(data)
	return (s_gsub(base64_encode(data), "[+/=]", b64url_rep));
end
local function unb64url(data)
	return base64_decode(s_gsub(data, "[-_]", b64url_rep).."==");
end

local function le64(n)
	return s_pack("<I8", bit.band(n, 0x7F));
end

local function pae(parts)
	local o = { le64(#parts) };
	for _, part in ipairs(parts) do
		table.insert(o, le64(#part)..part);
	end
	return table.concat(o);
end

function privkey_methods:export()
	return self.key:private_pem();
end

function pubkey_methods:export()
	return self.key:public_pem();
end

function v4_public.sign(m, sk, f, i)
	if getmetatable(sk) ~= v4_public_privkey_mt then
		error("cannot sign v4.public tokens with this key");
	end
	if type(m) ~= "table" then
		return nil, "PASETO payloads must be a table";
	end
	m = json.encode(m);
	local h = "v4.public.";
	local m2 = pae({ h, m, f or "", i or "" });
	local sig = crypto.ed25519_sign(sk.key, m2);
	if not f or f == "" then
		return h..b64url(m..sig);
	else
		return h..b64url(m..sig).."."..b64url(f);
	end
end

function v4_public.verify(tok, pk, expected_f, i)
	if getmetatable(pk) ~= v4_public_pubkey_mt then
		error("cannot verify v4.public tokens with this key");
	end
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
	local ok = crypto.ed25519_verify(pk.key, m2, s);
	if not ok then
		return nil, "invalid-token";
	end
	local payload, err = json.decode(m);
	if err ~= nil or type(payload) ~= "table" then
		return nil, "json-decode-error";
	end
	return payload;
end

function v4_public.new_keypair()
	local key = crypto.generate_ed25519_keypair();
	return {
		private_key = setmetatable({
			key = key;
		}, v4_public_privkey_mt);
		public_key = setmetatable({
			key = key;
		}, v4_public_pubkey_mt);
	};
end

function v4_public.import_public_key(pem)
	local key = crypto.import_public_pem(pem);
	assert(key:get_type() == "ED25519", "Invalid public key type for v4.public");
	return setmetatable({
		key = key;
	}, v4_public_pubkey_mt);
end

function v4_public.import_private_key(pem)
	local key = crypto.import_private_pem(pem);
	assert(key:get_type() == "ED25519", "Invalid private key type for v4.public");
	return setmetatable({
		key = key;
	}, v4_public_privkey_mt);
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
	return (select(2, v4_public.init(public_key_pem, options)));
end

return {
	pae = pae;
	v4_public = v4_public;
};
