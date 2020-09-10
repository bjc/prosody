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
#include <openssl/crypto.h>
#include <openssl/sha.h>
#include <openssl/md5.h>
#include <openssl/hmac.h>
#include <openssl/evp.h>

#if (LUA_VERSION_NUM == 501)
#define luaL_setfuncs(L, R, N) luaL_register(L, NULL, R)
#endif

#define HMAC_IPAD 0x36363636
#define HMAC_OPAD 0x5c5c5c5c

static const char *hex_tab = "0123456789abcdef";
static void toHex(const unsigned char *in, int length, unsigned char *out) {
	int i;

	for(i = 0; i < length; i++) {
		out[i * 2] = hex_tab[(in[i] >> 4) & 0xF];
		out[i * 2 + 1] = hex_tab[(in[i]) & 0xF];
	}
}

static int Levp_hash(lua_State *L, const EVP_MD *evp) {
	size_t len;
	unsigned int size = EVP_MAX_MD_SIZE;
	const char *s = luaL_checklstring(L, 1, &len);
	int hex_out = lua_toboolean(L, 2);

	unsigned char hash[EVP_MAX_MD_SIZE], result[EVP_MAX_MD_SIZE * 2];

	EVP_MD_CTX *ctx = EVP_MD_CTX_new();

	if(ctx == NULL) {
		goto fail;
	}

	if(!EVP_DigestInit_ex(ctx, evp, NULL)) {
		goto fail;
	}

	if(!EVP_DigestUpdate(ctx, s, len)) {
		goto fail;
	}

	if(!EVP_DigestFinal_ex(ctx, hash, &size)) {
		goto fail;
	}

	EVP_MD_CTX_free(ctx);

	if(hex_out) {
		toHex(hash, size, result);
		lua_pushlstring(L, (char *)result, size * 2);
	} else {
		lua_pushlstring(L, (char *)hash, size);
	}

	return 1;

fail:
	EVP_MD_CTX_free(ctx);
	return luaL_error(L, "hash function failed");
}

static int Lsha1(lua_State *L) {
	return Levp_hash(L, EVP_sha1());
}

static int Lsha224(lua_State *L) {
	return Levp_hash(L, EVP_sha224());
}

static int Lsha256(lua_State *L) {
	return Levp_hash(L, EVP_sha256());
}

static int Lsha384(lua_State *L) {
	return Levp_hash(L, EVP_sha384());
}

static int Lsha512(lua_State *L) {
	return Levp_hash(L, EVP_sha512());
}

static int Lmd5(lua_State *L) {
	return Levp_hash(L, EVP_md5());
}

struct hash_desc {
	int (*Init)(void *);
	int (*Update)(void *, const void *, size_t);
	int (*Final)(unsigned char *, void *);
	size_t digestLength;
	void *ctx, *ctxo;
};

#define MAKE_HMAC_FUNCTION(myFunc, evp, size, type) \
static int myFunc(lua_State *L) { \
	unsigned char hash[size], result[2*size]; \
	size_t key_len, msg_len; \
	unsigned int out_len; \
	const char *key = luaL_checklstring(L, 1, &key_len); \
	const char *msg = luaL_checklstring(L, 2, &msg_len); \
	const int hex_out = lua_toboolean(L, 3); \
	HMAC(evp(), key, key_len, (const unsigned char*)msg, msg_len, (unsigned char*)hash, &out_len); \
	if (hex_out) { \
		toHex(hash, out_len, result); \
		lua_pushlstring(L, (char*)result, out_len*2); \
	} else { \
		lua_pushlstring(L, (char*)hash, out_len); \
	} \
	return 1; \
}

MAKE_HMAC_FUNCTION(Lhmac_sha1, EVP_sha1, SHA_DIGEST_LENGTH, SHA_CTX)
MAKE_HMAC_FUNCTION(Lhmac_sha256, EVP_sha256, SHA256_DIGEST_LENGTH, SHA256_CTX)
MAKE_HMAC_FUNCTION(Lhmac_sha512, EVP_sha512, SHA512_DIGEST_LENGTH, SHA512_CTX)
MAKE_HMAC_FUNCTION(Lhmac_md5, EVP_md5, MD5_DIGEST_LENGTH, MD5_CTX)

static int Lpbkdf2_sha1(lua_State *L) {
	unsigned char out[SHA_DIGEST_LENGTH];

	size_t pass_len, salt_len;
	const char *pass = luaL_checklstring(L, 1, &pass_len);
	const unsigned char *salt = (unsigned char *)luaL_checklstring(L, 2, &salt_len);
	const int iter = luaL_checkinteger(L, 3);

	if(PKCS5_PBKDF2_HMAC(pass, pass_len, salt, salt_len, iter, EVP_sha1(), SHA_DIGEST_LENGTH, out) == 0) {
		return luaL_error(L, "PKCS5_PBKDF2_HMAC() failed");
	}

	lua_pushlstring(L, (char *)out, SHA_DIGEST_LENGTH);

	return 1;
}


static int Lpbkdf2_sha256(lua_State *L) {
	unsigned char out[SHA256_DIGEST_LENGTH];

	size_t pass_len, salt_len;
	const char *pass = luaL_checklstring(L, 1, &pass_len);
	const unsigned char *salt = (unsigned char *)luaL_checklstring(L, 2, &salt_len);
	const int iter = luaL_checkinteger(L, 3);

	if(PKCS5_PBKDF2_HMAC(pass, pass_len, salt, salt_len, iter, EVP_sha256(), SHA256_DIGEST_LENGTH, out) == 0) {
		return luaL_error(L, "PKCS5_PBKDF2_HMAC() failed");
	}

	lua_pushlstring(L, (char *)out, SHA256_DIGEST_LENGTH);
	return 1;
}

static int Lhash_equals(lua_State *L) {
	size_t len1, len2;
	const char *s1 = luaL_checklstring(L, 1, &len1);
	const char *s2 = luaL_checklstring(L, 2, &len2);
	if(len1 == len2) {
		lua_pushboolean(L, CRYPTO_memcmp(s1, s2, len1) == 0);
	} else {
		lua_pushboolean(L, 0);
	}
	return 1;
}

static const luaL_Reg Reg[] = {
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
	{ "scram_Hi_sha1",	Lpbkdf2_sha1	}, /* COMPAT */
	{ "pbkdf2_hmac_sha1",	Lpbkdf2_sha1	},
	{ "pbkdf2_hmac_sha256",	Lpbkdf2_sha256	},
	{ "equals",             Lhash_equals    },
	{ NULL,			NULL		}
};

LUALIB_API int luaopen_util_hashes(lua_State *L) {
#if (LUA_VERSION_NUM > 501)
	luaL_checkversion(L);
#endif
	lua_newtable(L);
	luaL_setfuncs(L, Reg, 0);
	lua_pushliteral(L, "-3.14");
	lua_setfield(L, -2, "version");
#ifdef OPENSSL_VERSION
	lua_pushstring(L, OpenSSL_version(OPENSSL_VERSION));
	lua_setfield(L, -2, "_LIBCRYPTO_VERSION");
#endif
	return 1;
}
