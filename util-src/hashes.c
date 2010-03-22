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

#include "lua.h"
#include "lauxlib.h"
#include <openssl/sha.h>
#include <openssl/md5.h>

const char* hex_tab = "0123456789abcdef";
void toHex(const char* in, int length, char* out) {
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
	char hash[size]; \
	char result[size*2]; \
	func((const unsigned char*)s, len, (unsigned char*)hash);  \
	if (hex_out) { \
		toHex(hash, size, result); \
		lua_pushlstring(L, result, size*2); \
	} else { \
		lua_pushlstring(L, hash, size);\
	} \
	return 1; \
}

MAKE_HASH_FUNCTION(Lsha1, SHA1, 20)
MAKE_HASH_FUNCTION(Lsha256, SHA256, 32)
MAKE_HASH_FUNCTION(Lmd5, MD5, 16)

static const luaL_Reg Reg[] =
{
	{ "sha1",	Lsha1	},
	{ "sha256",	Lsha256	},
	{ "md5",	Lmd5	},
	{ NULL,		NULL	}
};

LUALIB_API int luaopen_util_hashes(lua_State *L)
{
	luaL_register(L, "hashes", Reg);
	lua_pushliteral(L, "version");			/** version */
	lua_pushliteral(L, "-3.14");
	lua_settable(L,-3);
	return 1;
}
