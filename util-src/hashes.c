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

static int Lblake2s256(lua_State *L) {
	return Levp_hash(L, EVP_blake2s256());
}

static int Lblake2b512(lua_State *L) {
	return Levp_hash(L, EVP_blake2b512());
}

static int Lsha3_256(lua_State *L) {
	return Levp_hash(L, EVP_sha3_256());
}

static int Lsha3_512(lua_State *L) {
	return Levp_hash(L, EVP_sha3_512());
}

struct hash_desc {
	int (*Init)(void *);
	int (*Update)(void *, const void *, size_t);
	int (*Final)(unsigned char *, void *);
	size_t digestLength;
	void *ctx, *ctxo;
};

static int Levp_hmac(lua_State *L, const EVP_MD *evp) {
	unsigned char hash[EVP_MAX_MD_SIZE], result[EVP_MAX_MD_SIZE * 2];
	size_t key_len, msg_len;
	size_t out_len = EVP_MAX_MD_SIZE;
	const char *key = luaL_checklstring(L, 1, &key_len);
	const char *msg = luaL_checklstring(L, 2, &msg_len);
	const int hex_out = lua_toboolean(L, 3);

	EVP_PKEY *pkey = EVP_PKEY_new_raw_private_key(EVP_PKEY_HMAC, NULL, (unsigned char *)key, key_len);
	EVP_MD_CTX *ctx = EVP_MD_CTX_new();

	if(ctx == NULL || pkey == NULL) {
		goto fail;
	}

	if(!EVP_DigestSignInit(ctx, NULL, evp, NULL, pkey)) {
		goto fail;
	}

	if(!EVP_DigestSignUpdate(ctx, msg, msg_len)) {
		goto fail;
	}

	if(!EVP_DigestSignFinal(ctx, hash, &out_len)) {
		goto fail;
	}

	EVP_MD_CTX_free(ctx);
	EVP_PKEY_free(pkey);

	if(hex_out) {
		toHex(hash, out_len, result);
		lua_pushlstring(L, (char *)result, out_len * 2);
	} else {
		lua_pushlstring(L, (char *)hash, out_len);
	}

	return 1;

fail:
	EVP_MD_CTX_free(ctx);
	EVP_PKEY_free(pkey);
	return luaL_error(L, "hash function failed");
}

static int Lhmac_sha1(lua_State *L) {
	return Levp_hmac(L, EVP_sha1());
}

static int Lhmac_sha224(lua_State *L) {
	return Levp_hmac(L, EVP_sha224());
}

static int Lhmac_sha256(lua_State *L) {
	return Levp_hmac(L, EVP_sha256());
}

static int Lhmac_sha384(lua_State *L) {
	return Levp_hmac(L, EVP_sha384());
}

static int Lhmac_sha512(lua_State *L) {
	return Levp_hmac(L, EVP_sha512());
}

static int Lhmac_md5(lua_State *L) {
	return Levp_hmac(L, EVP_md5());
}

static int Lhmac_sha3_256(lua_State *L) {
	return Levp_hmac(L, EVP_sha3_256());
}

static int Lhmac_sha3_512(lua_State *L) {
	return Levp_hmac(L, EVP_sha3_512());
}

static int Lhmac_blake2s256(lua_State *L) {
	return Levp_hmac(L, EVP_blake2s256());
}

static int Lhmac_blake2b512(lua_State *L) {
	return Levp_hmac(L, EVP_blake2b512());
}


static int Levp_pbkdf2(lua_State *L, const EVP_MD *evp, size_t out_len) {
	unsigned char out[EVP_MAX_MD_SIZE];

	size_t pass_len, salt_len;
	const char *pass = luaL_checklstring(L, 1, &pass_len);
	const unsigned char *salt = (unsigned char *)luaL_checklstring(L, 2, &salt_len);
	const int iter = luaL_checkinteger(L, 3);

	if(PKCS5_PBKDF2_HMAC(pass, pass_len, salt, salt_len, iter, evp, out_len, out) == 0) {
		return luaL_error(L, "PKCS5_PBKDF2_HMAC() failed");
	}

	lua_pushlstring(L, (char *)out, out_len);

	return 1;
}

static int Lpbkdf2_sha1(lua_State *L) {
	return Levp_pbkdf2(L, EVP_sha1(), SHA_DIGEST_LENGTH);
}

static int Lpbkdf2_sha256(lua_State *L) {
	return Levp_pbkdf2(L, EVP_sha256(), SHA256_DIGEST_LENGTH);
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
	{ "sha3_256",		Lsha3_256	},
	{ "sha3_512",		Lsha3_512	},
	{ "blake2s256",		Lblake2s256	},
	{ "blake2b512",		Lblake2b512	},
	{ "hmac_sha1",		Lhmac_sha1	},
	{ "hmac_sha224",	Lhmac_sha224	},
	{ "hmac_sha256",	Lhmac_sha256	},
	{ "hmac_sha384",	Lhmac_sha384	},
	{ "hmac_sha512",	Lhmac_sha512	},
	{ "hmac_md5",		Lhmac_md5	},
	{ "hmac_sha3_256",	Lhmac_sha3_256	},
	{ "hmac_sha3_512",	Lhmac_sha3_512	},
	{ "hmac_blake2s256",	Lhmac_blake2s256	},
	{ "hmac_blake2b512",	Lhmac_blake2b512	},
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
