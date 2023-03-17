/* Prosody IM
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- Copyright (C) 2012 Paul Aurich
-- Copyright (C) 2013 Matthew Wild
-- Copyright (C) 2013 Florian Zeitz
--
*/

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <stddef.h>
#include <string.h>
#include <errno.h>

#ifndef _WIN32
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <net/if.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#endif

#include <lua.h>
#include <lauxlib.h>

#if (LUA_VERSION_NUM < 504)
#define luaL_pushfail lua_pushnil
#endif

/* Enumerate all locally configured IP addresses */

static const char *const type_strings[] = {
	"both",
	"ipv4",
	"ipv6",
	NULL
};

static int lc_local_addresses(lua_State *L) {
#ifndef _WIN32
	/* Link-local IPv4 addresses; see RFC 3927 and RFC 5735 */
	const uint32_t ip4_linklocal = htonl(0xa9fe0000); /* 169.254.0.0 */
	const uint32_t ip4_mask      = htonl(0xffff0000);
	struct ifaddrs *addr = NULL, *a;
#endif
	int n = 1;
	int type = luaL_checkoption(L, 1, "both", type_strings);
	const char link_local = lua_toboolean(L, 2); /* defaults to 0 (false) */
	const char ipv4 = (type == 0 || type == 1);
	const char ipv6 = (type == 0 || type == 2);

#ifndef _WIN32

	if(getifaddrs(&addr) < 0) {
		luaL_pushfail(L);
		lua_pushfstring(L, "getifaddrs failed (%d): %s", errno,
		                strerror(errno));
		return 2;
	}

#endif
	lua_newtable(L);

#ifndef _WIN32

	for(a = addr; a; a = a->ifa_next) {
		int family;
		char ipaddr[INET6_ADDRSTRLEN];
		const char *tmp = NULL;

		if(a->ifa_addr == NULL || a->ifa_flags & IFF_LOOPBACK) {
			continue;
		}

		family = a->ifa_addr->sa_family;

		if(ipv4 && family == AF_INET) {
			struct sockaddr_in *sa = (struct sockaddr_in *)a->ifa_addr;

			if(!link_local && ((sa->sin_addr.s_addr & ip4_mask) == ip4_linklocal)) {
				continue;
			}

			tmp = inet_ntop(family, &sa->sin_addr, ipaddr, sizeof(ipaddr));
		} else if(ipv6 && family == AF_INET6) {
			struct sockaddr_in6 *sa = (struct sockaddr_in6 *)a->ifa_addr;

			if(!link_local && IN6_IS_ADDR_LINKLOCAL(&sa->sin6_addr)) {
				continue;
			}

			if(IN6_IS_ADDR_V4MAPPED(&sa->sin6_addr) || IN6_IS_ADDR_V4COMPAT(&sa->sin6_addr)) {
				continue;
			}

			tmp = inet_ntop(family, &sa->sin6_addr, ipaddr, sizeof(ipaddr));
		}

		if(tmp != NULL) {
			lua_pushstring(L, tmp);
			lua_rawseti(L, -2, n++);
		}

		/* TODO: Error reporting? */
	}

	freeifaddrs(addr);
#else

	if(ipv4) {
		lua_pushstring(L, "0.0.0.0");
		lua_rawseti(L, -2, n++);
	}

	if(ipv6) {
		lua_pushstring(L, "::");
		lua_rawseti(L, -2, n++);
	}

#endif
	return 1;
}

static int lc_pton(lua_State *L) {
	char buf[16];
	const char *ipaddr = luaL_checkstring(L, 1);
	int errno_ = 0;
	int family = strchr(ipaddr, ':') ? AF_INET6 : AF_INET;

	switch(inet_pton(family, ipaddr, &buf)) {
		case 1:
			lua_pushlstring(L, buf, family == AF_INET6 ? 16 : 4);
			return 1;

		case -1:
			errno_ = errno;
			luaL_pushfail(L);
			lua_pushstring(L, strerror(errno_));
			lua_pushinteger(L, errno_);
			return 3;

		default:
		case 0:
			luaL_pushfail(L);
			lua_pushstring(L, strerror(EINVAL));
			lua_pushinteger(L, EINVAL);
			return 3;
	}

}

static int lc_ntop(lua_State *L) {
	char buf[INET6_ADDRSTRLEN];
	int family;
	int errno_;
	size_t l;
	const char *ipaddr = luaL_checklstring(L, 1, &l);

	if(l == 16) {
		family = AF_INET6;
	}
	else if(l == 4) {
		family = AF_INET;
	}
	else {
		luaL_pushfail(L);
		lua_pushstring(L, strerror(EAFNOSUPPORT));
		lua_pushinteger(L, EAFNOSUPPORT);
		return 3;
	}

	if(!inet_ntop(family, ipaddr, buf, INET6_ADDRSTRLEN))
	{
		errno_ = errno;
		luaL_pushfail(L);
		lua_pushstring(L, strerror(errno_));
		lua_pushinteger(L, errno_);
		return 3;
	}

	lua_pushstring(L, (const char *)(&buf));
	return 1;
}

int luaopen_prosody_util_net(lua_State *L) {
	luaL_checkversion(L);
	luaL_Reg exports[] = {
		{ "local_addresses", lc_local_addresses },
		{ "pton", lc_pton },
		{ "ntop", lc_ntop },
		{ NULL, NULL }
	};

	lua_createtable(L, 0, 1);
	luaL_setfuncs(L, exports, 0);
	return 1;
}
int luaopen_util_net(lua_State *L) {
	return luaopen_prosody_util_net(L);
}
