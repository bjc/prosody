/* Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2009 Tobias Markmann
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
*/

/*
* pposix.c
* POSIX support functions for Lua
*/

#define MODULE_VERSION "0.3.5"

#include <stdlib.h>
#include <math.h>
#include <unistd.h>
#include <libgen.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <fcntl.h>

#include <syslog.h>
#include <pwd.h>
#include <grp.h>

#include <string.h>
#include <errno.h>
#include "lua.h"
#include "lauxlib.h"

/* Daemonization support */

static int lc_daemonize(lua_State *L)
{

	pid_t pid;

	if ( getppid() == 1 )
	{
		lua_pushboolean(L, 0);
		lua_pushstring(L, "already-daemonized");
		return 2;
	}

	/* Attempt initial fork */
	if((pid = fork()) < 0)
	{
		/* Forking failed */
		lua_pushboolean(L, 0);
		lua_pushstring(L, "fork-failed");
		return 2;
	}
	else if(pid != 0)
	{
		/* We are the parent process */
		lua_pushboolean(L, 1);
		lua_pushnumber(L, pid);
		return 2;
	}

	/* and we are the child process */
	if(setsid() == -1)
	{
		/* We failed to become session leader */
		/* (we probably already were) */
		lua_pushboolean(L, 0);
		lua_pushstring(L, "setsid-failed");
		return 2;
	}

	/* Close stdin, stdout, stderr */
	close(0);
	close(1);
	close(2);

	/* Final fork, use it wisely */
	if(fork())
		exit(0);

	/* Show's over, let's continue */
	lua_pushboolean(L, 1);
	lua_pushnil(L);
	return 2;
}

/* Syslog support */

const char * const facility_strings[] = {
					"auth",
#if !(defined(sun) || defined(__sun))
					"authpriv",
#endif
					"cron",
					"daemon",
#if !(defined(sun) || defined(__sun))
					"ftp",
#endif
					"kern",
					"local0",
					"local1",
					"local2",
					"local3",
					"local4",
					"local5",
					"local6",
					"local7",
					"lpr",
					"mail",
					"syslog",
					"user",
					"uucp",
					NULL
				};
int facility_constants[] =	{
					LOG_AUTH,
#if !(defined(sun) || defined(__sun))
					LOG_AUTHPRIV,
#endif
					LOG_CRON,
					LOG_DAEMON,
#if !(defined(sun) || defined(__sun))
					LOG_FTP,
#endif
					LOG_KERN,
					LOG_LOCAL0,
					LOG_LOCAL1,
					LOG_LOCAL2,
					LOG_LOCAL3,
					LOG_LOCAL4,
					LOG_LOCAL5,
					LOG_LOCAL6,
					LOG_LOCAL7,
					LOG_LPR,
					LOG_MAIL,
					LOG_NEWS,
					LOG_SYSLOG,
					LOG_USER,
					LOG_UUCP,
					-1
				};

/* "
       The parameter ident in the call of openlog() is probably stored  as-is.
       Thus,  if  the  string  it  points  to  is  changed, syslog() may start
       prepending the changed string, and if the string it points to ceases to
       exist,  the  results  are  undefined.  Most portable is to use a string
       constant.
   " -- syslog manpage
*/
char* syslog_ident = NULL;

int lc_syslog_open(lua_State* L)
{
	int facility = luaL_checkoption(L, 2, "daemon", facility_strings);
	facility = facility_constants[facility];

	luaL_checkstring(L, 1);

	if(syslog_ident)
		free(syslog_ident);

	syslog_ident = strdup(lua_tostring(L, 1));

	openlog(syslog_ident, LOG_PID, facility);
	return 0;
}

const char * const level_strings[] = {
				"debug",
				"info",
				"notice",
				"warn",
				"error",
				NULL
			};
int level_constants[] = 	{
				LOG_DEBUG,
				LOG_INFO,
				LOG_NOTICE,
				LOG_WARNING,
				LOG_CRIT,
				-1
			};
int lc_syslog_log(lua_State* L)
{
	int level = luaL_checkoption(L, 1, "notice", level_strings);
	level = level_constants[level];

	luaL_checkstring(L, 2);

	syslog(level, "%s", lua_tostring(L, 2));
	return 0;
}

int lc_syslog_close(lua_State* L)
{
	closelog();
	if(syslog_ident)
	{
		free(syslog_ident);
		syslog_ident = NULL;
	}
	return 0;
}

int lc_syslog_setmask(lua_State* L)
{
	int level_idx = luaL_checkoption(L, 1, "notice", level_strings);
	int mask = 0;
	do
	{
		mask |= LOG_MASK(level_constants[level_idx]);
	} while (++level_idx<=4);

	setlogmask(mask);
	return 0;
}

/* getpid */

int lc_getpid(lua_State* L)
{
	lua_pushinteger(L, getpid());
	return 1;
}

/* UID/GID functions */

int lc_getuid(lua_State* L)
{
	lua_pushinteger(L, getuid());
	return 1;
}

int lc_getgid(lua_State* L)
{
	lua_pushinteger(L, getgid());
	return 1;
}

int lc_setuid(lua_State* L)
{
	int uid = -1;
	if(lua_gettop(L) < 1)
		return 0;
	if(!lua_isnumber(L, 1) && lua_tostring(L, 1))
	{
		/* Passed UID is actually a string, so look up the UID */
		struct passwd *p;
		p = getpwnam(lua_tostring(L, 1));
		if(!p)
		{
			lua_pushboolean(L, 0);
			lua_pushstring(L, "no-such-user");
			return 2;
		}
		uid = p->pw_uid;
	}
	else
	{
		uid = lua_tonumber(L, 1);
	}

	if(uid>-1)
	{
		/* Ok, attempt setuid */
		errno = 0;
		if(setuid(uid))
		{
			/* Fail */
			lua_pushboolean(L, 0);
			switch(errno)
			{
			case EINVAL:
				lua_pushstring(L, "invalid-uid");
				break;
			case EPERM:
				lua_pushstring(L, "permission-denied");
				break;
			default:
				lua_pushstring(L, "unknown-error");
			}
			return 2;
		}
		else
		{
			/* Success! */
			lua_pushboolean(L, 1);
			return 1;
		}
	}

	/* Seems we couldn't find a valid UID to switch to */
	lua_pushboolean(L, 0);
	lua_pushstring(L, "invalid-uid");
	return 2;
}

int lc_setgid(lua_State* L)
{
	int gid = -1;
	if(lua_gettop(L) < 1)
		return 0;
	if(!lua_isnumber(L, 1) && lua_tostring(L, 1))
	{
		/* Passed GID is actually a string, so look up the GID */
		struct group *g;
		g = getgrnam(lua_tostring(L, 1));
		if(!g)
		{
			lua_pushboolean(L, 0);
			lua_pushstring(L, "no-such-group");
			return 2;
		}
		gid = g->gr_gid;
	}
	else
	{
		gid = lua_tonumber(L, 1);
	}

	if(gid>-1)
	{
		/* Ok, attempt setgid */
		errno = 0;
		if(setgid(gid))
		{
			/* Fail */
			lua_pushboolean(L, 0);
			switch(errno)
			{
			case EINVAL:
				lua_pushstring(L, "invalid-gid");
				break;
			case EPERM:
				lua_pushstring(L, "permission-denied");
				break;
			default:
				lua_pushstring(L, "unknown-error");
			}
			return 2;
		}
		else
		{
			/* Success! */
			lua_pushboolean(L, 1);
			return 1;
		}
	}

	/* Seems we couldn't find a valid GID to switch to */
	lua_pushboolean(L, 0);
	lua_pushstring(L, "invalid-gid");
	return 2;
}

int lc_initgroups(lua_State* L)
{
	int ret;
	gid_t gid;
	struct passwd *p;

	if(!lua_isstring(L, 1))
	{
		lua_pushnil(L);
		lua_pushstring(L, "invalid-username");
		return 2;
	}
	p = getpwnam(lua_tostring(L, 1));
	if(!p)
	{
		lua_pushnil(L);
		lua_pushstring(L, "no-such-user");
		return 2;
	}
	if(lua_gettop(L) < 2)
		lua_pushnil(L);
	switch(lua_type(L, 2))
	{
	case LUA_TNIL:
		gid = p->pw_gid;
		break;
	case LUA_TNUMBER:
		gid = lua_tointeger(L, 2);
		break;
	default:
		lua_pushnil(L);
		lua_pushstring(L, "invalid-gid");
		return 2;
	}
	ret = initgroups(lua_tostring(L, 1), gid);
	switch(errno)
	{
	case 0:
		lua_pushboolean(L, 1);
		lua_pushnil(L);
		break;
	case ENOMEM:
		lua_pushnil(L);
		lua_pushstring(L, "no-memory");
		break;
	case EPERM:
		lua_pushnil(L);
		lua_pushstring(L, "permission-denied");
		break;
	default:
		lua_pushnil(L);
		lua_pushstring(L, "unknown-error");
	}
	return 2;
}

int lc_umask(lua_State* L)
{
	char old_mode_string[7];
	mode_t old_mode = umask(strtoul(luaL_checkstring(L, 1), NULL, 8));

	snprintf(old_mode_string, sizeof(old_mode_string), "%03o", old_mode);
	old_mode_string[sizeof(old_mode_string)-1] = 0;
	lua_pushstring(L, old_mode_string);

	return 1;
}

int lc_mkdir(lua_State* L)
{
	int ret = mkdir(luaL_checkstring(L, 1), S_IRUSR | S_IWUSR | S_IXUSR
		| S_IRGRP | S_IWGRP | S_IXGRP
		| S_IROTH | S_IXOTH); /* mode 775 */

	lua_pushboolean(L, ret==0);
	if(ret)
	{
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	return 1;
}

/*	Like POSIX's setrlimit()/getrlimit() API functions.
 *
 *	Syntax:
 *	pposix.setrlimit( resource, soft limit, hard limit)
 *
 *	Any negative limit will be replace with the current limit by an additional call of getrlimit().
 *
 *	Example usage:
 *	pposix.setrlimit("NOFILE", 1000, 2000)
 */
int string2resource(const char *s) {
	if (!strcmp(s, "CORE")) return RLIMIT_CORE;
	if (!strcmp(s, "CPU")) return RLIMIT_CPU;
	if (!strcmp(s, "DATA")) return RLIMIT_DATA;
	if (!strcmp(s, "FSIZE")) return RLIMIT_FSIZE;
	if (!strcmp(s, "NOFILE")) return RLIMIT_NOFILE;
	if (!strcmp(s, "STACK")) return RLIMIT_STACK;
#if !(defined(sun) || defined(__sun))
	if (!strcmp(s, "MEMLOCK")) return RLIMIT_MEMLOCK;
	if (!strcmp(s, "NPROC")) return RLIMIT_NPROC;
	if (!strcmp(s, "RSS")) return RLIMIT_RSS;
#endif
	return -1;
}

int lc_setrlimit(lua_State *L) {
	int arguments = lua_gettop(L);
	int softlimit = -1;
	int hardlimit = -1;
	const char *resource = NULL;
	int rid = -1;
	if(arguments < 1 || arguments > 3) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, "incorrect-arguments");
	}

	resource = luaL_checkstring(L, 1);
	softlimit = luaL_checkinteger(L, 2);
	hardlimit = luaL_checkinteger(L, 3);

	rid = string2resource(resource);
	if (rid != -1) {
		struct rlimit lim;
		struct rlimit lim_current;

		if (softlimit < 0 || hardlimit < 0) {
			if (getrlimit(rid, &lim_current)) {
				lua_pushboolean(L, 0);
				lua_pushstring(L, "getrlimit-failed");
				return 2;
			}
		}

		if (softlimit < 0) lim.rlim_cur = lim_current.rlim_cur;
			else lim.rlim_cur = softlimit;
		if (hardlimit < 0) lim.rlim_max = lim_current.rlim_max;
			else lim.rlim_max = hardlimit;

		if (setrlimit(rid, &lim)) {
			lua_pushboolean(L, 0);
			lua_pushstring(L, "setrlimit-failed");
			return 2;
		}
	} else {
		/* Unsupported resoucrce. Sorry I'm pretty limited by POSIX standard. */
		lua_pushboolean(L, 0);
		lua_pushstring(L, "invalid-resource");
		return 2;
	}
	lua_pushboolean(L, 1);
	return 1;
}

int lc_getrlimit(lua_State *L) {
	int arguments = lua_gettop(L);
	const char *resource = NULL;
	int rid = -1;
	struct rlimit lim;

	if (arguments != 1) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, "invalid-arguments");
		return 2;
	}

	resource = luaL_checkstring(L, 1);
	rid = string2resource(resource);
	if (rid != -1) {
		if (getrlimit(rid, &lim)) {
			lua_pushboolean(L, 0);
			lua_pushstring(L, "getrlimit-failed.");
			return 2;
		}
	} else {
		/* Unsupported resoucrce. Sorry I'm pretty limited by POSIX standard. */
		lua_pushboolean(L, 0);
		lua_pushstring(L, "invalid-resource");
		return 2;
	}
	lua_pushboolean(L, 1);
	lua_pushnumber(L, lim.rlim_cur);
	lua_pushnumber(L, lim.rlim_max);
	return 3;
}

int lc_abort(lua_State* L)
{
	abort();
	return 0;
}

int lc_uname(lua_State* L)
{
	struct utsname uname_info;
	if(uname(&uname_info) != 0)
	{
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	lua_newtable(L);
	lua_pushstring(L, uname_info.sysname);
	lua_setfield(L, -2, "sysname");
	lua_pushstring(L, uname_info.nodename);
	lua_setfield(L, -2, "nodename");
	lua_pushstring(L, uname_info.release);
	lua_setfield(L, -2, "release");
	lua_pushstring(L, uname_info.version);
	lua_setfield(L, -2, "version");
	lua_pushstring(L, uname_info.machine);
	lua_setfield(L, -2, "machine");
	return 1;
}

/* Register functions */

int luaopen_util_pposix(lua_State *L)
{
	luaL_Reg exports[] = {
		{ "abort", lc_abort },

		{ "daemonize", lc_daemonize },

		{ "syslog_open", lc_syslog_open },
		{ "syslog_close", lc_syslog_close },
		{ "syslog_log", lc_syslog_log },
		{ "syslog_setminlevel", lc_syslog_setmask },

		{ "getpid", lc_getpid },
		{ "getuid", lc_getuid },
		{ "getgid", lc_getgid },

		{ "setuid", lc_setuid },
		{ "setgid", lc_setgid },
		{ "initgroups", lc_initgroups },

		{ "umask", lc_umask },

		{ "mkdir", lc_mkdir },

		{ "setrlimit", lc_setrlimit },
		{ "getrlimit", lc_getrlimit },

		{ "uname", lc_uname },

		{ NULL, NULL }
	};

	luaL_register(L, "pposix",  exports);

	lua_pushliteral(L, "pposix");
	lua_setfield(L, -2, "_NAME");

	lua_pushliteral(L, MODULE_VERSION);
	lua_setfield(L, -2, "_VERSION");

	return 1;
}
