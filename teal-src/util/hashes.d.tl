local type hash = function (msg : string, hex : boolean) : string
local type hmac = function (key : string, msg : string, hex : boolean) : string
local type kdf = function (pass : string, salt : string, i : integer) : string

local record lib
	sha1 : hash
	sha256 : hash
	sha224 : hash
	sha384 : hash
	sha512 : hash
	md5 : hash
	blake2s256 : hash
	blake2b512 : hash
	hmac_sha1 : hmac
	hmac_sha256 : hmac
	hmac_sha224 : hmac
	hmac_sha384  :hmac
	hmac_sha512 : hmac
	hmac_md5 : hmac
	scram_Hi_sha1 : kdf
	pbkdf2_hmac_sha1 : kdf
	pbkdf2_hmac_sha256 : kdf
	equals : function (string, string) : boolean
	version : string
	_LIBCRYPTO_VERSION : string
end
return lib
