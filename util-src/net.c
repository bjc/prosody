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

/* Enumerate all locally configured IP addresses */

const char * const type_strings[] = {
	"both",
	"ipv4",
	"ipv6",
	NULL
};

static int lc_local_addresses(lua_State *L)
{
	/* Link-local IPv4 addresses; see RFC 3927 and RFC 5735 */
	const long ip4_linklocal = htonl(0xa9fe0000); /* 169.254.0.0 */
	const long ip4_mask      = htonl(0xffff0000);
#ifndef _WIN32
	struct ifaddrs *addr = NULL, *a;
	int n = 1;
#endif
	int type = luaL_checkoption(L, 1, "both", type_strings);
	const char link_local = lua_toboolean(L, 2); /* defaults to 0 (false) */
	const char ipv4 = (type == 0 || type == 1);
	const char ipv6 = (type == 0 || type == 2);

#ifndef _WIN32
	if (getifaddrs(&addr) < 0) {
		lua_pushnil(L);
		lua_pushfstring(L, "getifaddrs failed (%d): %s", errno,
		strerror(errno));
		return 2;
	}

	lua_newtable(L);

	for (a = addr; a; a = a->ifa_next) {
		int family;
		char ipaddr[INET6_ADDRSTRLEN];
		const char *tmp = NULL;

		if (a->ifa_addr == NULL || a->ifa_flags & IFF_LOOPBACK)
			continue;

		family = a->ifa_addr->sa_family;

		if (ipv4 && family == AF_INET) {
			struct sockaddr_in *sa = (struct sockaddr_in *)a->ifa_addr;
			if (!link_local &&((sa->sin_addr.s_addr & ip4_mask) == ip4_linklocal))
				continue;
			tmp = inet_ntop(family, &sa->sin_addr, ipaddr, sizeof(ipaddr));
		} else if (ipv6 && family == AF_INET6) {
			struct sockaddr_in6 *sa = (struct sockaddr_in6 *)a->ifa_addr;
			if (!link_local && IN6_IS_ADDR_LINKLOCAL(&sa->sin6_addr))
				continue;
			if (IN6_IS_ADDR_V4MAPPED(&sa->sin6_addr) || IN6_IS_ADDR_V4COMPAT(&sa->sin6_addr))
				continue;
			tmp = inet_ntop(family, &sa->sin6_addr, ipaddr, sizeof(ipaddr));
		}

		if (tmp != NULL) {
			lua_pushstring(L, tmp);
			lua_rawseti(L, -2, n++);
		}
		/* TODO: Error reporting? */
	}

	freeifaddrs(addr);

	return 1;
#endif
}

int luaopen_util_net(lua_State* L)
{
	luaL_Reg exports[] = {
		{ "local_addresses", lc_local_addresses },
		{ NULL, NULL }
	};

	luaL_register(L, "net",  exports);
	return 1;
}
