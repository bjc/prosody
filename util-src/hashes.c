/* Prosody IM v0.1
-- Copyright (C) 2008 Matthew Wild
-- Copyright (C) 2008 Waqas Hussain
-- 
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- as published by the Free Software Foundation; either version 2
-- of the License, or (at your option) any later version.
-- 
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- 
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
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
