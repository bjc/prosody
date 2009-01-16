/* Prosody IM v0.1
-- Copyright (C) 2008 Matthew Wild
-- Copyright (C) 2008 Waqas Hussain
-- 
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- as published by the Free Software Foundation; either version 2
-- of the License, or (at your option) any later version.
-- 
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- 
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
*/

/* pposix.c
   POSIX support functions for Lua
*/

#define MODULE_VERSION "0.3.0"

#include <stdlib.h>
#include <unistd.h>
#include <libgen.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

#include <syslog.h>

#include <string.h>

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
/*	close(0);
	close(1);
	close(2);
*/
	/* Final fork, use it wisely */
	if(fork())
		exit(0);

	/* Show's over, let's continue */
	lua_pushboolean(L, 1);
	lua_pushnil(L);
	return 2;
}

/* Syslog support */

char *facility_strings[] = 	{ 	"auth",
					"authpriv",
					"cron",
					"daemon",
					"ftp",
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
					LOG_AUTHPRIV,
					LOG_CRON,
					LOG_DAEMON,
					LOG_FTP,
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
	int facility = luaL_checkoption(L, 2, "daemon", &facility_strings);
	facility = facility_constants[facility];

	luaL_checkstring(L, 1);
	
	if(syslog_ident)
		free(syslog_ident);
	
	syslog_ident = strdup(lua_tostring(L, 1));
	
	openlog(syslog_ident, LOG_PID, facility);
	return 0;
}

char *level_strings[] = 	{
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
				LOG_EMERG,
				-1
			};
int lc_syslog_log(lua_State* L)
{
	int level = luaL_checkoption(L, 1, "notice", &level_strings);
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
	int level_idx = luaL_checkoption(L, 1, "notice", &level_strings);
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

/* Register functions */

int luaopen_util_pposix(lua_State *L)
{
	lua_newtable(L);

	lua_pushcfunction(L, lc_daemonize);
	lua_setfield(L, -2, "daemonize");

	lua_pushcfunction(L, lc_syslog_open);
	lua_setfield(L, -2, "syslog_open");

	lua_pushcfunction(L, lc_syslog_close);
	lua_setfield(L, -2, "syslog_close");

	lua_pushcfunction(L, lc_syslog_log);
	lua_setfield(L, -2, "syslog_log");

	lua_pushcfunction(L, lc_syslog_setmask);
	lua_setfield(L, -2, "syslog_setminlevel");

	lua_pushcfunction(L, lc_getpid);
	lua_setfield(L, -2, "getpid");

	lua_pushliteral(L, "pposix");
	lua_setfield(L, -2, "_NAME");

	lua_pushliteral(L, MODULE_VERSION);
	lua_setfield(L, -2, "_VERSION");
	
	return 1;
};
