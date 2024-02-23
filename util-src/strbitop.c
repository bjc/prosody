/*
 * This project is MIT licensed. Please see the
 * COPYING file in the source package for more information.
 *
 * Copyright (C) 2016 Kim Alvefur
 */

#include <lua.h>
#include <lauxlib.h>

#include <sys/param.h>
#include <limits.h>

/* TODO Deduplicate code somehow */

static int strop_and(lua_State *L) {
	luaL_Buffer buf;
	size_t a, b, i;
	const char *str_a = luaL_checklstring(L, 1, &a);
	const char *str_b = luaL_checklstring(L, 2, &b);

	luaL_buffinit(L, &buf);

	if(a == 0 || b == 0) {
		lua_settop(L, 1);
		return 1;
	}

	for(i = 0; i < a; i++) {
		luaL_addchar(&buf, str_a[i] & str_b[i % b]);
	}

	luaL_pushresult(&buf);
	return 1;
}

static int strop_or(lua_State *L) {
	luaL_Buffer buf;
	size_t a, b, i;
	const char *str_a = luaL_checklstring(L, 1, &a);
	const char *str_b = luaL_checklstring(L, 2, &b);

	luaL_buffinit(L, &buf);

	if(a == 0 || b == 0) {
		lua_settop(L, 1);
		return 1;
	}

	for(i = 0; i < a; i++) {
		luaL_addchar(&buf, str_a[i] | str_b[i % b]);
	}

	luaL_pushresult(&buf);
	return 1;
}

static int strop_xor(lua_State *L) {
	luaL_Buffer buf;
	size_t a, b, i;
	const char *str_a = luaL_checklstring(L, 1, &a);
	const char *str_b = luaL_checklstring(L, 2, &b);

	luaL_buffinit(L, &buf);

	if(a == 0 || b == 0) {
		lua_settop(L, 1);
		return 1;
	}

	for(i = 0; i < a; i++) {
		luaL_addchar(&buf, str_a[i] ^ str_b[i % b]);
	}

	luaL_pushresult(&buf);
	return 1;
}

unsigned int clz(unsigned char c) {
#if __GNUC__
	return __builtin_clz((unsigned int) c) - ((sizeof(int)-1)*CHAR_BIT);
#else
	if(c & 0x80) return 0;
	if(c & 0x40) return 1;
	if(c & 0x20) return 2;
	if(c & 0x10) return 3;
	if(c & 0x08) return 4;
	if(c & 0x04) return 5;
	if(c & 0x02) return 6;
	if(c & 0x01) return 7;
	return 8;
#endif
}

LUA_API int strop_common_prefix_bits(lua_State *L) {
	size_t a, b, i;
	const char *str_a = luaL_checklstring(L, 1, &a);
	const char *str_b = luaL_checklstring(L, 2, &b);

	size_t min_len = MIN(a, b);

	for(i=0; i<min_len; i++) {
		if(str_a[i] != str_b[i]) {
			lua_pushinteger(L, i*8 + (clz(str_a[i] ^ str_b[i])));
			return 1;
		}
	}

	lua_pushinteger(L, i*8);
	return 1;
}

LUA_API int luaopen_prosody_util_strbitop(lua_State *L) {
	luaL_Reg exports[] = {
		{ "sand", strop_and },
		{ "sor",  strop_or },
		{ "sxor", strop_xor },
		{ "common_prefix_bits", strop_common_prefix_bits },
		{ NULL, NULL }
	};

	lua_newtable(L);
	luaL_setfuncs(L, exports, 0);
	return 1;
}

LUA_API int luaopen_util_strbitop(lua_State *L) {
	return luaopen_prosody_util_strbitop(L);
}
