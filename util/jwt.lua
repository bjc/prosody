local s_gsub = string.gsub;
local json = require "util.json";
local hashes = require "util.hashes";
local base64_encode = require "util.encodings".base64.encode;
local base64_decode = require "util.encodings".base64.decode;

local b64url_rep = { ["+"] = "-", ["/"] = "_", ["="] = "", ["-"] = "+", ["_"] = "/" };
local function b64url(data)
	return (s_gsub(base64_encode(data), "[+/=]", b64url_rep));
end
local function unb64url(data)
	return base64_decode(s_gsub(data, "[-_]", b64url_rep).."==");
end

local static_header = b64url('{"alg":"HS256","typ":"JWT"}') .. '.';

local function sign(key, payload)
	local encoded_payload = json.encode(payload);
	local signed = static_header .. b64url(encoded_payload);
	local signature = hashes.hmac_sha256(key, signed);
	return signed .. "." .. b64url(signature);
end

local jwt_pattern = "^(([A-Za-z0-9-_]+)%.([A-Za-z0-9-_]+))%.([A-Za-z0-9-_]+)$"
local function verify(key, blob)
	local signed, bheader, bpayload, signature = string.match(blob, jwt_pattern);
	if not signed then
		return nil, "invalid-encoding";
	end
	local header = json.decode(unb64url(bheader));
	if not header or type(header) ~= "table" then
		return nil, "invalid-header";
	elseif header.alg ~= "HS256" then
		return nil, "unsupported-algorithm";
	end
	if b64url(hashes.hmac_sha256(key, signed)) ~= signature then
		return false, "signature-mismatch";
	end
	local payload, err = json.decode(unb64url(bpayload));
	if err ~= nil then
		return nil, "json-decode-error";
	end
	return true, payload;
end

return {
	sign = sign;
	verify = verify;
};

