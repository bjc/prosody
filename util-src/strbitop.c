/*
 * This project is MIT licensed. Please see the
 * COPYING file in the source package for more information.
 *
 * Copyright (C) 2016 Kim Alvefur
 */

#include <lua.h>
#include <lauxlib.h>


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

LUA_API int luaopen_prosody_util_strbitop(lua_State *L) {
	luaL_Reg exports[] = {
		{ "sand", strop_and },
		{ "sor",  strop_or },
		{ "sxor", strop_xor },
		{ NULL, NULL }
	};

	lua_newtable(L);
	luaL_setfuncs(L, exports, 0);
	return 1;
}

LUA_API int luaopen_util_strbitop(lua_State *L) {
	return luaopen_prosody_util_strbitop(L);
}
