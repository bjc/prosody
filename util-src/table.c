#include <lua.h>
#include <lauxlib.h>

static int Lcreate_table(lua_State* L) {
	lua_createtable(L, luaL_checkinteger(L, 1), luaL_checkinteger(L, 2));
	return 1;
}

int luaopen_util_table(lua_State *L) {
	lua_newtable(L);
	lua_pushcfunction(L, Lcreate_table);
	lua_setfield(L, -2, "create");
	return 1;
}
