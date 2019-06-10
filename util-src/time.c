#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#include <time.h>
#include <lua.h>

lua_Number tv2number(struct timespec *tv) {
	return tv->tv_sec + tv->tv_nsec * 1e-9;
}

int lc_time_realtime(lua_State *L) {
	struct timespec t;
	clock_gettime(CLOCK_REALTIME, &t);
	lua_pushnumber(L, tv2number(&t));
	return 1;
}

int lc_time_monotonic(lua_State *L) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	lua_pushnumber(L, tv2number(&t));
	return 1;
}

int luaopen_util_time(lua_State *L) {
	lua_createtable(L, 0, 2);
	{
		lua_pushcfunction(L, lc_time_realtime);
		lua_setfield(L, -2, "now");
		lua_pushcfunction(L, lc_time_monotonic);
		lua_setfield(L, -2, "monotonic");
	}
	return 1;
}
