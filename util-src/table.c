#include <lua.h>
#include <lauxlib.h>

#ifndef LUA_MAXINTEGER
#include <stdint.h>
#define LUA_MAXINTEGER PTRDIFF_MAX
#endif

static int Lcreate_table(lua_State *L) {
	lua_createtable(L, luaL_checkinteger(L, 1), luaL_checkinteger(L, 2));
	return 1;
}

/* COMPAT: w/ Lua pre-5.4 */
static int Lpack(lua_State *L) {
	unsigned int n_args = lua_gettop(L);
	lua_createtable(L, n_args, 1);
	lua_insert(L, 1);

	for(int arg = n_args; arg >= 1; arg--) {
		lua_rawseti(L, 1, arg);
	}

	lua_pushinteger(L, n_args);
	lua_setfield(L, -2, "n");
	return 1;
}

/* COMPAT: w/ Lua pre-5.4 */
static int Lmove (lua_State *L) {
	lua_Integer f = luaL_checkinteger(L, 2);
	lua_Integer e = luaL_checkinteger(L, 3);
	lua_Integer t = luaL_checkinteger(L, 4);

	int tt = !lua_isnoneornil(L, 5) ? 5 : 1;  /* destination table */
	luaL_checktype(L, 1, LUA_TTABLE);
	luaL_checktype(L, tt, LUA_TTABLE);

	if (e >= f) {  /* otherwise, nothing to move */
		lua_Integer n, i;
		luaL_argcheck(L, f > 0 || e < LUA_MAXINTEGER + f, 3,
		  "too many elements to move");
		n = e - f + 1;  /* number of elements to move */
		luaL_argcheck(L, t <= LUA_MAXINTEGER - n + 1, 4,
		"destination wrap around");
		if (t > e || t <= f || (tt != 1 && !lua_compare(L, 1, tt, LUA_OPEQ))) {
			for (i = 0; i < n; i++) {
				lua_rawgeti(L, 1, f + i);
				lua_rawseti(L, tt, t + i);
			}
		} else {
			for (i = n - 1; i >= 0; i--) {
				lua_rawgeti(L, 1, f + i);
				lua_rawseti(L, tt, t + i);
			}
		}
	}

	lua_pushvalue(L, tt);  /* return destination table */
	return 1;
}

int luaopen_util_table(lua_State *L) {
	luaL_checkversion(L);
	lua_createtable(L, 0, 2);
	lua_pushcfunction(L, Lcreate_table);
	lua_setfield(L, -2, "create");
	lua_pushcfunction(L, Lpack);
	lua_setfield(L, -2, "pack");
	lua_pushcfunction(L, Lmove);
	lua_setfield(L, -2, "move");
	return 1;
}
