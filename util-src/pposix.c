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

#define MODULE_VERSION "0.4.0"


#if defined(__linux__)
#define _GNU_SOURCE
#else
#define _DEFAULT_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L

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
#include "lualib.h"
#include "lauxlib.h"

#if (LUA_VERSION_NUM == 501)
#define luaL_setfuncs(L, R, N) luaL_register(L, NULL, R)
#endif

#include <fcntl.h>
#if defined(__linux__)
#include <linux/falloc.h>
#endif

#if !defined(WITHOUT_MALLINFO) && defined(__linux__)
#include <malloc.h>
#define WITH_MALLINFO
#endif

#if defined(__FreeBSD__) && defined(RFPROC)
/*
 * On FreeBSD, calling fork() is equivalent to rfork(RFPROC | RFFDG).
 *
 * RFFDG being set means that the file descriptor table is copied,
 * otherwise it's shared. We want the later, otherwise libevent gets
 * messed up.
 *
 * See issue #412
 */
#define fork() rfork(RFPROC)
#endif

/* Daemonization support */

static int lc_daemonize(lua_State *L) {

	pid_t pid;

	if(getppid() == 1) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, "already-daemonized");
		return 2;
	}

	/* Attempt initial fork */
	if((pid = fork()) < 0) {
		/* Forking failed */
		lua_pushboolean(L, 0);
		lua_pushstring(L, "fork-failed");
		return 2;
	} else if(pid != 0) {
		/* We are the parent process */
		lua_pushboolean(L, 1);
		lua_pushnumber(L, pid);
		return 2;
	}

	/* and we are the child process */
	if(setsid() == -1) {
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
	/* Make sure accidental use of FDs 0, 1, 2 don't cause weirdness */
	open("/dev/null", O_RDONLY);
	open("/dev/null", O_WRONLY);
	open("/dev/null", O_WRONLY);

	/* Final fork, use it wisely */
	if(fork()) {
		exit(0);
	}

	/* Show's over, let's continue */
	lua_pushboolean(L, 1);
	lua_pushnil(L);
	return 2;
}

/* Syslog support */

const char *const facility_strings[] = {
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
char *syslog_ident = NULL;

int lc_syslog_open(lua_State *L) {
	int facility = luaL_checkoption(L, 2, "daemon", facility_strings);
	facility = facility_constants[facility];

	luaL_checkstring(L, 1);

	if(syslog_ident) {
		free(syslog_ident);
	}

	syslog_ident = strdup(lua_tostring(L, 1));

	openlog(syslog_ident, LOG_PID, facility);
	return 0;
}

const char *const level_strings[] = {
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
int lc_syslog_log(lua_State *L) {
	int level = level_constants[luaL_checkoption(L, 1, "notice", level_strings)];

	if(lua_gettop(L) == 3) {
		syslog(level, "%s: %s", luaL_checkstring(L, 2), luaL_checkstring(L, 3));
	} else {
		syslog(level, "%s", lua_tostring(L, 2));
	}

	return 0;
}

int lc_syslog_close(lua_State *L) {
	closelog();

	if(syslog_ident) {
		free(syslog_ident);
		syslog_ident = NULL;
	}

	return 0;
}

int lc_syslog_setmask(lua_State *L) {
	int level_idx = luaL_checkoption(L, 1, "notice", level_strings);
	int mask = 0;

	do {
		mask |= LOG_MASK(level_constants[level_idx]);
	} while(++level_idx <= 4);

	setlogmask(mask);
	return 0;
}

/* getpid */

int lc_getpid(lua_State *L) {
	lua_pushinteger(L, getpid());
	return 1;
}

/* UID/GID functions */

int lc_getuid(lua_State *L) {
	lua_pushinteger(L, getuid());
	return 1;
}

int lc_getgid(lua_State *L) {
	lua_pushinteger(L, getgid());
	return 1;
}

int lc_setuid(lua_State *L) {
	int uid = -1;

	if(lua_gettop(L) < 1) {
		return 0;
	}

	if(!lua_isnumber(L, 1) && lua_tostring(L, 1)) {
		/* Passed UID is actually a string, so look up the UID */
		struct passwd *p;
		p = getpwnam(lua_tostring(L, 1));

		if(!p) {
			lua_pushboolean(L, 0);
			lua_pushstring(L, "no-such-user");
			return 2;
		}

		uid = p->pw_uid;
	} else {
		uid = lua_tonumber(L, 1);
	}

	if(uid > -1) {
		/* Ok, attempt setuid */
		errno = 0;

		if(setuid(uid)) {
			/* Fail */
			lua_pushboolean(L, 0);

			switch(errno) {
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
		} else {
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

int lc_setgid(lua_State *L) {
	int gid = -1;

	if(lua_gettop(L) < 1) {
		return 0;
	}

	if(!lua_isnumber(L, 1) && lua_tostring(L, 1)) {
		/* Passed GID is actually a string, so look up the GID */
		struct group *g;
		g = getgrnam(lua_tostring(L, 1));

		if(!g) {
			lua_pushboolean(L, 0);
			lua_pushstring(L, "no-such-group");
			return 2;
		}

		gid = g->gr_gid;
	} else {
		gid = lua_tonumber(L, 1);
	}

	if(gid > -1) {
		/* Ok, attempt setgid */
		errno = 0;

		if(setgid(gid)) {
			/* Fail */
			lua_pushboolean(L, 0);

			switch(errno) {
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
		} else {
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

int lc_initgroups(lua_State *L) {
	int ret;
	gid_t gid;
	struct passwd *p;

	if(!lua_isstring(L, 1)) {
		lua_pushnil(L);
		lua_pushstring(L, "invalid-username");
		return 2;
	}

	p = getpwnam(lua_tostring(L, 1));

	if(!p) {
		lua_pushnil(L);
		lua_pushstring(L, "no-such-user");
		return 2;
	}

	if(lua_gettop(L) < 2) {
		lua_pushnil(L);
	}

	switch(lua_type(L, 2)) {
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

	if(ret) {
		switch(errno) {
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
	} else {
		lua_pushboolean(L, 1);
		lua_pushnil(L);
	}

	return 2;
}

int lc_umask(lua_State *L) {
	char old_mode_string[7];
	mode_t old_mode = umask(strtoul(luaL_checkstring(L, 1), NULL, 8));

	snprintf(old_mode_string, sizeof(old_mode_string), "%03o", old_mode);
	old_mode_string[sizeof(old_mode_string) - 1] = 0;
	lua_pushstring(L, old_mode_string);

	return 1;
}

int lc_mkdir(lua_State *L) {
	int ret = mkdir(luaL_checkstring(L, 1), S_IRUSR | S_IWUSR | S_IXUSR
	                | S_IRGRP | S_IWGRP | S_IXGRP
	                | S_IROTH | S_IXOTH); /* mode 775 */

	lua_pushboolean(L, ret == 0);

	if(ret) {
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
	if(!strcmp(s, "CORE")) {
		return RLIMIT_CORE;
	}

	if(!strcmp(s, "CPU")) {
		return RLIMIT_CPU;
	}

	if(!strcmp(s, "DATA")) {
		return RLIMIT_DATA;
	}

	if(!strcmp(s, "FSIZE")) {
		return RLIMIT_FSIZE;
	}

	if(!strcmp(s, "NOFILE")) {
		return RLIMIT_NOFILE;
	}

	if(!strcmp(s, "STACK")) {
		return RLIMIT_STACK;
	}

#if !(defined(sun) || defined(__sun))

	if(!strcmp(s, "MEMLOCK")) {
		return RLIMIT_MEMLOCK;
	}

	if(!strcmp(s, "NPROC")) {
		return RLIMIT_NPROC;
	}

	if(!strcmp(s, "RSS")) {
		return RLIMIT_RSS;
	}

#endif
#ifdef RLIMIT_NICE

	if(!strcmp(s, "NICE")) {
		return RLIMIT_NICE;
	}

#endif
	return -1;
}

rlim_t arg_to_rlimit(lua_State *L, int idx, rlim_t current) {
	switch(lua_type(L, idx)) {
		case LUA_TSTRING:

			if(strcmp(lua_tostring(L, idx), "unlimited") == 0) {
				return RLIM_INFINITY;
			}

		case LUA_TNUMBER:
			return lua_tointeger(L, idx);

		case LUA_TNONE:
		case LUA_TNIL:
			return current;

		default:
			return luaL_argerror(L, idx, "unexpected type");
	}
}

int lc_setrlimit(lua_State *L) {
	struct rlimit lim;
	int arguments = lua_gettop(L);
	int rid = -1;

	if(arguments < 1 || arguments > 3) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, "incorrect-arguments");
		return 2;
	}

	rid = string2resource(luaL_checkstring(L, 1));

	if(rid == -1) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, "invalid-resource");
		return 2;
	}

	/* Fetch current values to use as defaults */
	if(getrlimit(rid, &lim)) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, "getrlimit-failed");
		return 2;
	}

	lim.rlim_cur = arg_to_rlimit(L, 2, lim.rlim_cur);
	lim.rlim_max = arg_to_rlimit(L, 3, lim.rlim_max);

	if(setrlimit(rid, &lim)) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, "setrlimit-failed");
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

	if(arguments != 1) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, "invalid-arguments");
		return 2;
	}

	resource = luaL_checkstring(L, 1);
	rid = string2resource(resource);

	if(rid != -1) {
		if(getrlimit(rid, &lim)) {
			lua_pushboolean(L, 0);
			lua_pushstring(L, "getrlimit-failed.");
			return 2;
		}
	} else {
		/* Unsupported resource. Sorry I'm pretty limited by POSIX standard. */
		lua_pushboolean(L, 0);
		lua_pushstring(L, "invalid-resource");
		return 2;
	}

	lua_pushboolean(L, 1);

	if(lim.rlim_cur == RLIM_INFINITY) {
		lua_pushstring(L, "unlimited");
	} else {
		lua_pushnumber(L, lim.rlim_cur);
	}

	if(lim.rlim_max == RLIM_INFINITY) {
		lua_pushstring(L, "unlimited");
	} else {
		lua_pushnumber(L, lim.rlim_max);
	}

	return 3;
}

int lc_abort(lua_State *L) {
	abort();
	return 0;
}

int lc_uname(lua_State *L) {
	struct utsname uname_info;

	if(uname(&uname_info) != 0) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}

	lua_createtable(L, 0, 6);
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
#ifdef __USE_GNU
	lua_pushstring(L, uname_info.domainname);
	lua_setfield(L, -2, "domainname");
#endif
	return 1;
}

int lc_setenv(lua_State *L) {
	const char *var = luaL_checkstring(L, 1);
	const char *value;

	/* If the second argument is nil or nothing, unset the var */
	if(lua_isnoneornil(L, 2)) {
		if(unsetenv(var) != 0) {
			lua_pushnil(L);
			lua_pushstring(L, strerror(errno));
			return 2;
		}

		lua_pushboolean(L, 1);
		return 1;
	}

	value = luaL_checkstring(L, 2);

	if(setenv(var, value, 1) != 0) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}

	lua_pushboolean(L, 1);
	return 1;
}

#ifdef WITH_MALLINFO
int lc_meminfo(lua_State *L) {
	struct mallinfo info = mallinfo();
	lua_createtable(L, 0, 5);
	/* This is the total size of memory allocated with sbrk by malloc, in bytes. */
	lua_pushinteger(L, info.arena);
	lua_setfield(L, -2, "allocated");
	/* This is the total size of memory allocated with mmap, in bytes. */
	lua_pushinteger(L, info.hblkhd);
	lua_setfield(L, -2, "allocated_mmap");
	/* This is the total size of memory occupied by chunks handed out by malloc. */
	lua_pushinteger(L, info.uordblks);
	lua_setfield(L, -2, "used");
	/* This is the total size of memory occupied by free (not in use) chunks. */
	lua_pushinteger(L, info.fordblks);
	lua_setfield(L, -2, "unused");
	/* This is the size of the top-most releasable chunk that normally borders the
	   end of the heap (i.e., the high end of the virtual address space's data segment). */
	lua_pushinteger(L, info.keepcost);
	lua_setfield(L, -2, "returnable");
	return 1;
}
#endif

/*
 * Append some data to a file handle
 * Attempt to allocate space first
 * Truncate to original size on failure
 */
int lc_atomic_append(lua_State *L) {
	int err;
	size_t len;

	FILE *f = *(FILE **) luaL_checkudata(L, 1, LUA_FILEHANDLE);
	const char *data = luaL_checklstring(L, 2, &len);

	off_t offset = ftell(f);

#if defined(__linux__)
	/* Try to allocate space without changing the file size. */
	if((err = fallocate(fileno(f), FALLOC_FL_KEEP_SIZE, offset, len))) {
		if(errno != 0) {
			/* Some old versions of Linux apparently use the return value instead of errno */
			err = errno;
		}
		switch(err) {
			case ENOSYS: /* Kernel doesn't implement fallocate */
			case EOPNOTSUPP: /* Filesystem doesn't support it */
				/* Ignore and proceed to try to write */
				break;

			case ENOSPC: /* No space left */
			default: /* Other issues */
				lua_pushnil(L);
				lua_pushstring(L, strerror(err));
				lua_pushinteger(L, err);
				return 3;
		}
	}
#endif

	if(fwrite(data, sizeof(char), len, f) == len) {
		if(fflush(f) == 0) {
			lua_pushboolean(L, 1); /* Great success! */
			return 1;
		} else {
			err = errno;
		}
	} else {
		err = ferror(f);
	}

	fseek(f, offset, SEEK_SET);

	/* Cut partially written data */
	if(ftruncate(fileno(f), offset)) {
		/* The file is now most likely corrupted, throw hard error */
		return luaL_error(L, "atomic_append() failed in ftruncate(): %s", strerror(errno));
	}

	lua_pushnil(L);
	lua_pushstring(L, strerror(err));
	lua_pushinteger(L, err);
	return 3;
}

/* Register functions */

int luaopen_util_pposix(lua_State *L) {
#if (LUA_VERSION_NUM > 501)
	luaL_checkversion(L);
#endif
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

		{ "setenv", lc_setenv },

#ifdef WITH_MALLINFO
		{ "meminfo", lc_meminfo },
#endif

		{ "atomic_append", lc_atomic_append },

		{ NULL, NULL }
	};

	lua_newtable(L);
	luaL_setfuncs(L, exports, 0);

#ifdef ENOENT
	lua_pushinteger(L, ENOENT);
	lua_setfield(L, -2, "ENOENT");
#endif

	lua_pushliteral(L, "pposix");
	lua_setfield(L, -2, "_NAME");

	lua_pushliteral(L, MODULE_VERSION);
	lua_setfield(L, -2, "_VERSION");

	return 1;
}
