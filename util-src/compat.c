
#include <lua.h>
#include <lauxlib.h>


static int lc_xpcall (lua_State *L) {
  int ret;
  int n_arg = lua_gettop(L);
  /* f, msgh, p1, p2... */
  luaL_argcheck(L, n_arg >= 2, 2, "value expected");
  lua_pushvalue(L, 1);  /* f to top */
  lua_pushvalue(L, 2);  /* msgh to top */
  lua_replace(L, 1); /* msgh to 1 */
  lua_replace(L, 2); /* f to 2 */
  /* msgh, f, p1, p2... */
  ret = lua_pcall(L, n_arg - 2, LUA_MULTRET, 1);
  lua_pushboolean(L, ret == 0);
  lua_replace(L, 1);
  return lua_gettop(L);
}

int luaopen_prosody_util_compat(lua_State *L) {
	lua_createtable(L, 0, 2);
	{
		lua_pushcfunction(L, lc_xpcall);
		lua_setfield(L, -2, "xpcall");
	}
	return 1;
}

int luaopen_util_compat(lua_State *L) {
	return luaopen_prosody_util_compat(L);
}
