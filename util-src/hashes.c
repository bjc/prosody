/* Prosody IM
-- Copyright (C) 2009-2010 Matthew Wild
-- Copyright (C) 2009-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
*/


/*
* hashes.c
* Lua library for sha1, sha256 and md5 hashes
*/

#include <string.h>
#include <stdlib.h>

#ifdef _MSC_VER
typedef unsigned __int32 uint32_t;
#else
#include <inttypes.h>
#endif

#include "lua.h"
#include "lauxlib.h"
#include <openssl/sha.h>
#include <openssl/md5.h>

#define HMAC_IPAD 0x36363636
#define HMAC_OPAD 0x5c5c5c5c

const char *hex_tab = "0123456789abcdef";
void toHex(const unsigned char *in, int length, unsigned char *out) {
	int i;
	for (i = 0; i < length; i++) {
		out[i*2] = hex_tab[(in[i] >> 4) & 0xF];
		out[i*2+1] = hex_tab[(in[i]) & 0xF];
	}
}

#define MAKE_HASH_FUNCTION(myFunc, func, size) \
static int myFunc(lua_State *L) { \
	size_t len; \
	const char *s = luaL_checklstring(L, 1, &len); \
	int hex_out = lua_toboolean(L, 2); \
	unsigned char hash[size], result[size*2]; \
	func((const unsigned char*)s, len, hash);  \
	if (hex_out) { \
		toHex(hash, size, result); \
		lua_pushlstring(L, (char*)result, size*2); \
	} else { \
		lua_pushlstring(L, (char*)hash, size);\
	} \
	return 1; \
}

MAKE_HASH_FUNCTION(Lsha1, SHA1, SHA_DIGEST_LENGTH)
MAKE_HASH_FUNCTION(Lsha224, SHA224, SHA224_DIGEST_LENGTH)
MAKE_HASH_FUNCTION(Lsha256, SHA256, SHA256_DIGEST_LENGTH)
MAKE_HASH_FUNCTION(Lsha384, SHA384, SHA384_DIGEST_LENGTH)
MAKE_HASH_FUNCTION(Lsha512, SHA512, SHA512_DIGEST_LENGTH)
MAKE_HASH_FUNCTION(Lmd5, MD5, MD5_DIGEST_LENGTH)

struct hash_desc {
	int (*Init)(void*);
	int (*Update)(void*, const void *, size_t);
	int (*Final)(unsigned char*, void*);
	size_t digestLength;
	void *ctx, *ctxo;
};

static void hmac(struct hash_desc *desc, const char *key, size_t key_len,
    const char *msg, size_t msg_len, unsigned char *result)
{
	union xory {
		unsigned char bytes[64];
		uint32_t quadbytes[16];
	};

	int i;
	unsigned char hashedKey[64]; /* Maximum used digest length */
	union xory k_ipad, k_opad;

	if (key_len > 64) {
		desc->Init(desc->ctx);
		desc->Update(desc->ctx, key, key_len);
		desc->Final(hashedKey, desc->ctx);
		key = (const char*)hashedKey;
		key_len = desc->digestLength;
	}

	memcpy(k_ipad.bytes, key, key_len);
	memset(k_ipad.bytes + key_len, 0, 64 - key_len);
	memcpy(k_opad.bytes, k_ipad.bytes, 64);

	for (i = 0; i < 16; i++) {
		k_ipad.quadbytes[i] ^= HMAC_IPAD;
		k_opad.quadbytes[i] ^= HMAC_OPAD;
	}

	desc->Init(desc->ctx);
	desc->Update(desc->ctx, k_ipad.bytes, 64);
	desc->Init(desc->ctxo);
	desc->Update(desc->ctxo, k_opad.bytes, 64);
	desc->Update(desc->ctx, msg, msg_len);
	desc->Final(result, desc->ctx);
	desc->Update(desc->ctxo, result, desc->digestLength);
	desc->Final(result, desc->ctxo);
}

#define MAKE_HMAC_FUNCTION(myFunc, func, size, type) \
static int myFunc(lua_State *L) { \
	type ctx, ctxo; \
	unsigned char hash[size], result[2*size]; \
	size_t key_len, msg_len; \
	const char *key = luaL_checklstring(L, 1, &key_len); \
	const char *msg = luaL_checklstring(L, 2, &msg_len); \
	const int hex_out = lua_toboolean(L, 3); \
	struct hash_desc desc; \
	desc.Init = (int (*)(void*))func##_Init; \
	desc.Update = (int (*)(void*, const void *, size_t))func##_Update; \
	desc.Final = (int (*)(unsigned char*, void*))func##_Final; \
	desc.digestLength = size; \
	desc.ctx = &ctx; \
	desc.ctxo = &ctxo; \
	hmac(&desc, key, key_len, msg, msg_len, hash); \
	if (hex_out) { \
		toHex(hash, size, result); \
		lua_pushlstring(L, (char*)result, size*2); \
	} else { \
		lua_pushlstring(L, (char*)hash, size); \
	} \
	return 1; \
}

MAKE_HMAC_FUNCTION(Lhmac_sha1, SHA1, SHA_DIGEST_LENGTH, SHA_CTX)
MAKE_HMAC_FUNCTION(Lhmac_sha256, SHA256, SHA256_DIGEST_LENGTH, SHA256_CTX)
MAKE_HMAC_FUNCTION(Lhmac_sha512, SHA512, SHA512_DIGEST_LENGTH, SHA512_CTX)
MAKE_HMAC_FUNCTION(Lhmac_md5, MD5, MD5_DIGEST_LENGTH, MD5_CTX)

static int LscramHi(lua_State *L) {
	union xory {
		unsigned char bytes[SHA_DIGEST_LENGTH];
		uint32_t quadbytes[SHA_DIGEST_LENGTH/4];
	};
	int i;
	SHA_CTX ctx, ctxo;
	unsigned char Ust[SHA_DIGEST_LENGTH];
	union xory Und;
	union xory res;
	size_t str_len, salt_len;
	struct hash_desc desc;
	const char *str = luaL_checklstring(L, 1, &str_len);
	const char *salt = luaL_checklstring(L, 2, &salt_len);
	char *salt2;
	const int iter = luaL_checkinteger(L, 3);

	desc.Init = (int (*)(void*))SHA1_Init;
	desc.Update = (int (*)(void*, const void *, size_t))SHA1_Update;
	desc.Final = (int (*)(unsigned char*, void*))SHA1_Final;
	desc.digestLength = SHA_DIGEST_LENGTH;
	desc.ctx = &ctx;
	desc.ctxo = &ctxo;

	salt2 = malloc(salt_len + 4);
	if (salt2 == NULL)
		luaL_error(L, "Out of memory in scramHi");
	memcpy(salt2, salt, salt_len);
	memcpy(salt2 + salt_len, "\0\0\0\1", 4);
	hmac(&desc, str, str_len, salt2, salt_len + 4, Ust);
	free(salt2);

	memcpy(res.bytes, Ust, sizeof(res));
	for (i = 1; i < iter; i++) {
		int j;
		hmac(&desc, str, str_len, (char*)Ust, sizeof(Ust), Und.bytes);
		for (j = 0; j < SHA_DIGEST_LENGTH/4; j++)
			res.quadbytes[j] ^= Und.quadbytes[j];
		memcpy(Ust, Und.bytes, sizeof(Ust));
	}

	lua_pushlstring(L, (char*)res.bytes, SHA_DIGEST_LENGTH);

	return 1;
}

static const luaL_Reg Reg[] =
{
	{ "sha1",		Lsha1		},
	{ "sha224",		Lsha224		},
	{ "sha256",		Lsha256		},
	{ "sha384",		Lsha384		},
	{ "sha512",		Lsha512		},
	{ "md5",		Lmd5		},
	{ "hmac_sha1",		Lhmac_sha1	},
	{ "hmac_sha256",	Lhmac_sha256	},
	{ "hmac_sha512",	Lhmac_sha512	},
	{ "hmac_md5",		Lhmac_md5	},
	{ "scram_Hi_sha1",	LscramHi	},
	{ NULL,			NULL		}
};

LUALIB_API int luaopen_util_hashes(lua_State *L)
{
	lua_newtable(L);
	luaL_register(L, NULL, Reg);
	lua_pushliteral(L, "version");			/** version */
	lua_pushliteral(L, "-3.14");
	lua_settable(L,-3);
	return 1;
}
