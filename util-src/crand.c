/* Prosody IM
-- Copyright (C) 2008-2017 Matthew Wild
-- Copyright (C) 2008-2017 Waqas Hussain
-- Copyright (C) 2016-2017 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
*/

/*
* crand.c
* C PRNG interface
*
* The purpose of this module is to provide access to a PRNG in
* environments without /dev/urandom
*
* Caution! This has not been extensively tested.
*
*/

#define _DEFAULT_SOURCE

#include "lualib.h"
#include "lauxlib.h"

#include <string.h>
#include <errno.h>

#if defined(WITH_GETRANDOM)

#ifndef __GLIBC_PREREQ
#define __GLIBC_PREREQ(a,b) 0
#endif

#if ! __GLIBC_PREREQ(2,25)
#include <unistd.h>
#include <sys/syscall.h>

#ifndef SYS_getrandom
#error getrandom() requires Linux 3.17 or later
#endif

/* This wasn't present before glibc 2.25 */
int getrandom(void *buf, size_t buflen, unsigned int flags) {
	return syscall(SYS_getrandom, buf, buflen, flags);
}
#else
#include <sys/random.h>
#endif

#elif defined(WITH_ARC4RANDOM)
#include <stdlib.h>
#elif defined(WITH_OPENSSL)
#include <openssl/rand.h>
#else
#error util.crand compiled without a random source
#endif

int Lrandom(lua_State *L) {
	int ret = 0;
	size_t len = (size_t)luaL_checkinteger(L, 1);
	void *buf = lua_newuserdata(L, len);

#if defined(WITH_GETRANDOM)
	/*
	 * This acts like a read from /dev/urandom with the exception that it
	 * *does* block if the entropy pool is not yet initialized.
	 */
	ret = getrandom(buf, len, 0);

	if(ret < 0) {
		lua_pushstring(L, strerror(errno));
		return lua_error(L);
	}

#elif defined(WITH_ARC4RANDOM)
	arc4random_buf(buf, len);
	ret = len;
#elif defined(WITH_OPENSSL)
	if(!RAND_status()) {
		lua_pushliteral(L, "OpenSSL PRNG not seeded");
		return lua_error(L);
	}

	ret = RAND_bytes(buf, len);

	if(ret == 1) {
		ret = len;
	} else {
		/* TODO ERR_get_error() */
		lua_pushstring(L, "RAND_bytes() failed");
		return lua_error(L);
	}

#endif

	lua_pushlstring(L, buf, ret);
	return 1;
}

int luaopen_util_crand(lua_State *L) {
#if (LUA_VERSION_NUM > 501)
	luaL_checkversion(L);
#endif

	lua_createtable(L, 0, 2);
	lua_pushcfunction(L, Lrandom);
	lua_setfield(L, -2, "bytes");

#if defined(WITH_GETRANDOM)
	lua_pushstring(L, "Linux");
#elif defined(WITH_ARC4RANDOM)
	lua_pushstring(L, "arc4random()");
#elif defined(WITH_OPENSSL)
	lua_pushstring(L, "OpenSSL");
#endif
	lua_setfield(L, -2, "_source");

	return 1;
}

