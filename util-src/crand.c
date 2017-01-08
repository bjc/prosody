/* Prosody IM
-- Copyright (C) 2008-2016 Matthew Wild
-- Copyright (C) 2008-2016 Waqas Hussain
-- Copyright (C) 2016 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
*/

/*
* crand.c
* C PRNG interface
*/

#include "lualib.h"
#include "lauxlib.h"

#include <string.h>
#include <errno.h>

/*
 * TODO: Decide on fixed size or dynamically allocated buffer
 */
#if 1
#include <stdlib.h>
#else
#define BUFLEN 256
#endif

#if defined(WITH_GETRANDOM)
#include <unistd.h>
#include <sys/syscall.h>
#include <linux/random.h>

#ifndef SYS_getrandom
#error getrandom() requires Linux 3.17 or later
#endif

/* Was this not supposed to be a function? */
int getrandom(char *buf, size_t len, int flags) {
	return syscall(SYS_getrandom, buf, len, flags);
}

#elif defined(WITH_ARC4RANDOM)
#include <stdlib.h>
#elif defined(WITH_OPENSSL)
#include <openssl/rand.h>
#else
#error util.crand compiled without a random source
#endif

int Lrandom(lua_State *L) {
#ifdef BUFLEN
	unsigned char buf[BUFLEN];
#else
	unsigned char *buf;
#endif
	int ret = 0;
	size_t len = (size_t)luaL_checkint(L, 1);
#ifdef BUFLEN
	len = len > BUFLEN ? BUFLEN : len;
#else
	buf = malloc(len);

	if(buf == NULL) {
		lua_pushnil(L);
		lua_pushstring(L, "out of memory");
		/* or it migth be better to
		 * return lua_error(L);
		 */
		return 2;
	}
#endif

#if defined(WITH_GETRANDOM)
	ret = getrandom(buf, len, 0);

	if(ret < 0) {
#ifndef BUFLEN
		free(buf);
#endif
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		lua_pushinteger(L, errno);
		return 3;
	}

#elif defined(WITH_ARC4RANDOM)
	arc4random_buf(buf, len);
	ret = len;
#elif defined(WITH_OPENSSL)
	ret = RAND_bytes(buf, len);

	if(ret == 1) {
		ret = len;
	} else {
#ifndef BUFLEN
		free(buf);
#endif
		lua_pushnil(L);
		lua_pushstring(L, "failed");
		/* lua_pushinteger(L, ERR_get_error()); */
		return 2;
	}

#endif

	lua_pushlstring(L, (const char *)buf, ret);
#ifndef BUFLEN
	free(buf);
#endif
	return 1;
}

#ifdef ENABLE_SEEDING
int Lseed(lua_State *L) {
	size_t len;
	const char *seed = lua_tolstring(L, 1, &len);

#if defined(WITH_OPENSSL)
	RAND_add(seed, len, len);
	return 0;
#else
	lua_pushnil(L);
	lua_pushliteral(L, "not-supported");
	return 2;
#endif
}
#endif

int luaopen_util_crand(lua_State *L) {
#if (LUA_VERSION_NUM > 501)
	luaL_checkversion(L);
#endif
	lua_newtable(L);
	lua_pushcfunction(L, Lrandom);
	lua_setfield(L, -2, "bytes");
#ifdef ENABLE_SEEDING
	lua_pushcfunction(L, Lseed);
	lua_setfield(L, -2, "seed");
#endif

#if defined(WITH_GETRANDOM)
	lua_pushstring(L, "Linux");
#elif defined(WITH_ARC4RANDOM)
	lua_pushstring(L, "arc4random()");
#elif defined(WITH_OPENSSL)
	lua_pushstring(L, "OpenSSL");
#endif
	lua_setfield(L, -2, "_source");

#if defined(WITH_OPENSSL) && defined(_WIN32)
	/* Do we need to seed this on Windows? */
#endif

	return 1;
}

