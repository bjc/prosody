/*
 * signal.c -- Signal Handler Library for Lua
 *
 * Version: 1.000+changes
 *
 * Copyright (C) 2007  Patrick J. Donnelly (batrick@batbytes.com)
 *
 * This software is distributed under the same license as Lua 5.0:
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included
 * in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
 * OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
 * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
*/

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#ifdef __linux__
#define HAVE_SIGNALFD
#endif

#include <signal.h>
#include <stdlib.h>
#include <unistd.h>
#ifdef HAVE_SIGNALFD
#include <sys/signalfd.h>
#endif

#include "lua.h"
#include "lauxlib.h"

#if (LUA_VERSION_NUM < 503)
#define lua_isinteger(L, n) lua_isnumber(L, n)
#endif

#ifndef lsig

#define lsig

struct lua_signal {
	char *name; /* name of the signal */
	int sig; /* the signal */
};

#endif

#define MAX_PENDING_SIGNALS 32

#define LUA_SIGNAL "lua_signal"

static const struct lua_signal lua_signals[] = {
	/* ANSI C signals */
#ifdef SIGABRT
	{"SIGABRT", SIGABRT},
#endif
#ifdef SIGFPE
	{"SIGFPE", SIGFPE},
#endif
#ifdef SIGILL
	{"SIGILL", SIGILL},
#endif
#ifdef SIGINT
	{"SIGINT", SIGINT},
#endif
#ifdef SIGSEGV
	{"SIGSEGV", SIGSEGV},
#endif
#ifdef SIGTERM
	{"SIGTERM", SIGTERM},
#endif
	/* posix signals */
#ifdef SIGHUP
	{"SIGHUP", SIGHUP},
#endif
#ifdef SIGQUIT
	{"SIGQUIT", SIGQUIT},
#endif
#ifdef SIGTRAP
	{"SIGTRAP", SIGTRAP},
#endif
#ifdef SIGKILL
	{"SIGKILL", SIGKILL},
#endif
#ifdef SIGUSR1
	{"SIGUSR1", SIGUSR1},
#endif
#ifdef SIGUSR2
	{"SIGUSR2", SIGUSR2},
#endif
#ifdef SIGPIPE
	{"SIGPIPE", SIGPIPE},
#endif
#ifdef SIGALRM
	{"SIGALRM", SIGALRM},
#endif
#ifdef SIGCHLD
	{"SIGCHLD", SIGCHLD},
#endif
#ifdef SIGCONT
	{"SIGCONT", SIGCONT},
#endif
#ifdef SIGSTOP
	{"SIGSTOP", SIGSTOP},
#endif
#ifdef SIGTTIN
	{"SIGTTIN", SIGTTIN},
#endif
#ifdef SIGTTOU
	{"SIGTTOU", SIGTTOU},
#endif
	/* some BSD signals */
#ifdef SIGIOT
	{"SIGIOT", SIGIOT},
#endif
#ifdef SIGBUS
	{"SIGBUS", SIGBUS},
#endif
#ifdef SIGCLD
	{"SIGCLD", SIGCLD},
#endif
#ifdef SIGURG
	{"SIGURG", SIGURG},
#endif
#ifdef SIGXCPU
	{"SIGXCPU", SIGXCPU},
#endif
#ifdef SIGXFSZ
	{"SIGXFSZ", SIGXFSZ},
#endif
#ifdef SIGVTALRM
	{"SIGVTALRM", SIGVTALRM},
#endif
#ifdef SIGPROF
	{"SIGPROF", SIGPROF},
#endif
#ifdef SIGWINCH
	{"SIGWINCH", SIGWINCH},
#endif
#ifdef SIGPOLL
	{"SIGPOLL", SIGPOLL},
#endif
#ifdef SIGIO
	{"SIGIO", SIGIO},
#endif
	/* add odd signals */
#ifdef SIGSTKFLT
	{"SIGSTKFLT", SIGSTKFLT}, /* stack fault */
#endif
#ifdef SIGSYS
	{"SIGSYS", SIGSYS},
#endif
	{NULL, 0}
};

static lua_State *Lsig = NULL;
static lua_Hook Hsig = NULL;
static int Hmask = 0;
static int Hcount = 0;

static int signals[MAX_PENDING_SIGNALS];
static int nsig = 0;

static void sighook(lua_State *L, lua_Debug *ar) {
	(void)ar;
	/* restore the old hook */
	lua_sethook(L, Hsig, Hmask, Hcount);

	lua_pushstring(L, LUA_SIGNAL);
	lua_gettable(L, LUA_REGISTRYINDEX);

	for(int i = 0; i < nsig; i++) {
		lua_pushinteger(L, signals[i]);
		lua_gettable(L, -2);
		lua_call(L, 0, 0);
	};

	nsig = 0;

	lua_pop(L, 1); /* pop lua_signal table */

}

static void handle(int sig) {
	if(nsig == 0) {
		/* Store the existing debug hook (if any) and its parameters */
		Hsig = lua_gethook(Lsig);
		Hmask = lua_gethookmask(Lsig);
		Hcount = lua_gethookcount(Lsig);

		/* Set our new debug hook */
		lua_sethook(Lsig, sighook, LUA_MASKCALL | LUA_MASKRET | LUA_MASKCOUNT, 1);
	}

	if(nsig < MAX_PENDING_SIGNALS) {
		signals[nsig++] = sig;
	}
}

/*
 * l_signal == signal(signal [, func [, chook]])
 *
 * signal = signal number or string
 * func = Lua function to call
 * chook = catch within C functions
 *         if caught, Lua function _must_
 *         exit, as the stack is most likely
 *         in an unstable state.
*/

static int l_signal(lua_State *L) {
	int args = lua_gettop(L);
	int t, sig; /* type, signal */

	/* get type of signal */
	luaL_checkany(L, 1);
	t = lua_type(L, 1);

	if(t == LUA_TNUMBER) {
		sig = (int) lua_tointeger(L, 1);
	} else if(t == LUA_TSTRING) {
		lua_pushstring(L, LUA_SIGNAL);
		lua_gettable(L, LUA_REGISTRYINDEX);
		lua_pushvalue(L, 1);
		lua_gettable(L, -2);

		if(!lua_isinteger(L, -1)) {
			return luaL_error(L, "invalid signal string");
		}

		sig = (int) lua_tointeger(L, -1);
		lua_pop(L, 1); /* get rid of number we pushed */
	} else {
		luaL_checknumber(L, 1);    /* will always error, with good error msg */
		return luaL_error(L, "unreachable: invalid number was accepted");
	}

	/* set handler */
	if(args == 1 || lua_isnil(L, 2)) { /* clear handler */
		lua_pushstring(L, LUA_SIGNAL);
		lua_gettable(L, LUA_REGISTRYINDEX);
		lua_pushinteger(L, sig);
		lua_gettable(L, -2); /* return old handler */
		lua_pushinteger(L, sig);
		lua_pushnil(L);
		lua_settable(L, -4);
		lua_remove(L, -2); /* remove LUA_SIGNAL table */
		signal(sig, SIG_DFL);
	} else {
		luaL_checktype(L, 2, LUA_TFUNCTION);

		lua_pushstring(L, LUA_SIGNAL);
		lua_gettable(L, LUA_REGISTRYINDEX);

		lua_pushinteger(L, sig);
		lua_pushvalue(L, 2);
		lua_settable(L, -3);

		/* Set the state for the handler */
		Lsig = L;

		if(lua_toboolean(L, 3)) { /* c hook? */
			if(signal(sig, handle) == SIG_ERR) {
				lua_pushboolean(L, 0);
			} else {
				lua_pushboolean(L, 1);
			}
		} else { /* lua_hook */
			if(signal(sig, handle) == SIG_ERR) {
				lua_pushboolean(L, 0);
			} else {
				lua_pushboolean(L, 1);
			}
		}
	}

	return 1;
}

/*
 * l_raise == raise(signal)
 *
 * signal = signal number or string
*/

static int l_raise(lua_State *L) {
	/* int args = lua_gettop(L); */
	int t = 0; /* type */
	lua_Integer ret;

	luaL_checkany(L, 1);

	t = lua_type(L, 1);

	if(t == LUA_TNUMBER) {
		ret = (lua_Integer) raise((int) lua_tointeger(L, 1));
		lua_pushinteger(L, ret);
	} else if(t == LUA_TSTRING) {
		lua_pushstring(L, LUA_SIGNAL);
		lua_gettable(L, LUA_REGISTRYINDEX);
		lua_pushvalue(L, 1);
		lua_gettable(L, -2);

		if(!lua_isnumber(L, -1)) {
			return luaL_error(L, "invalid signal string");
		}

		ret = (lua_Integer) raise((int) lua_tointeger(L, -1));
		lua_pop(L, 1); /* get rid of number we pushed */
		lua_pushinteger(L, ret);
	} else {
		luaL_checknumber(L, 1);    /* will always error, with good error msg */
	}

	return 1;
}

#if defined(__unix__) || defined(__APPLE__)

/* define some posix only functions */

/*
 * l_kill == kill(pid, signal)
 *
 * pid = process id
 * signal = signal number or string
*/

static int l_kill(lua_State *L) {
	int t; /* type */
	lua_Integer ret; /* return value */

	luaL_checknumber(L, 1); /* must be int for pid */
	luaL_checkany(L, 2); /* check for a second arg */

	t = lua_type(L, 2);

	if(t == LUA_TNUMBER) {
		ret = (lua_Integer) kill((int) lua_tointeger(L, 1),
		                         (int) lua_tointeger(L, 2));
		lua_pushinteger(L, ret);
	} else if(t == LUA_TSTRING) {
		lua_pushstring(L, LUA_SIGNAL);
		lua_gettable(L, LUA_REGISTRYINDEX);
		lua_pushvalue(L, 2);
		lua_gettable(L, -2);

		if(!lua_isnumber(L, -1)) {
			return luaL_error(L, "invalid signal string");
		}

		ret = (lua_Integer) kill((int) lua_tointeger(L, 1),
		                         (int) lua_tointeger(L, -1));
		lua_pop(L, 1); /* get rid of number we pushed */
		lua_pushinteger(L, ret);
	} else {
		luaL_checknumber(L, 2);    /* will always error, with good error msg */
	}

	return 1;
}

#endif

struct lsignalfd {
	int fd;
	sigset_t mask;
#ifndef HAVE_SIGNALFD
	int write_fd;
#endif
};

#ifndef HAVE_SIGNALFD
#define MAX_SIGNALFD 32
struct lsignalfd signalfds[MAX_SIGNALFD];
static int signalfd_num = 0;
static void signal2fd(int sig) {
	for(int i = 0; i < signalfd_num; i++) {
		if(sigismember(&signalfds[i].mask, sig)) {
			write(signalfds[i].write_fd, &sig, sizeof(sig));
		}
	}
}
#endif

static int l_signalfd(lua_State *L) {
	struct lsignalfd *sfd = lua_newuserdata(L, sizeof(struct lsignalfd));
	int sig = luaL_checkinteger(L, 1);

	sigemptyset(&sfd->mask);
	sigaddset(&sfd->mask, sig);

#ifdef HAVE_SIGNALFD
	if (sigprocmask(SIG_BLOCK, &sfd->mask, NULL) != 0) {
		lua_pushnil(L);
		return 1;
	};

	sfd->fd = signalfd(-1, &sfd->mask, SFD_NONBLOCK);

	if(sfd->fd == -1) {
		lua_pushnil(L);
		return 1;
	}

#else

	if(signalfd_num >= MAX_SIGNALFD) {
		lua_pushnil(L);
		return 1;
	}

	if(signal(sig, signal2fd) == SIG_ERR) {
		lua_pushnil(L);
		return 1;
	}

	int pipefd[2];

	if(pipe(pipefd) == -1) {
		lua_pushnil(L);
		return 1;
	}

	sfd->fd = pipefd[0];
	sfd->write_fd = pipefd[1];
	signalfds[signalfd_num++] = *sfd;
#endif

	luaL_setmetatable(L, "signalfd");
	return 1;
}

static int l_signalfd_getfd(lua_State *L) {
	struct lsignalfd *sfd = luaL_checkudata(L, 1, "signalfd");

	if (sfd->fd == -1) {
		lua_pushnil(L);
		return 1;
	}

	lua_pushinteger(L, sfd->fd);
	return 1;
}

static int l_signalfd_read(lua_State *L) {
	struct lsignalfd *sfd = luaL_checkudata(L, 1, "signalfd");
#ifdef HAVE_SIGNALFD
	struct signalfd_siginfo siginfo;

	if(read(sfd->fd, &siginfo, sizeof(siginfo)) < 0) {
		return 0;
	}


	lua_pushinteger(L, siginfo.ssi_signo);
	return 1;

#else
	int signo;

	if(read(sfd->fd, &signo, sizeof(int)) < 0) {
		return 0;
	}

	lua_pushinteger(L, signo);
	return 1;
#endif

}

static int l_signalfd_close(lua_State *L) {
	struct lsignalfd *sfd = luaL_checkudata(L, 1, "signalfd");

	if(close(sfd->fd) != 0) {
		lua_pushboolean(L, 0);
		return 1;
	}

#ifndef HAVE_SIGNALFD

	if(close(sfd->write_fd) != 0) {
		lua_pushboolean(L, 0);
		return 1;
	}

	for(int i = signalfd_num; i > 0; i--) {
		if(signalfds[i].fd == sfd->fd) {
			signalfds[i] = signalfds[signalfd_num--];
		}
	}

#endif

	sfd->fd = -1;
	lua_pushboolean(L, 1);
	return 1;
}

static const struct luaL_Reg lsignal_lib[] = {
	{"signal", l_signal},
	{"raise", l_raise},
#if defined(__unix__) || defined(__APPLE__)
	{"kill", l_kill},
#endif
	{"signalfd", l_signalfd},
	{NULL, NULL}
};

int luaopen_prosody_util_signal(lua_State *L) {
	luaL_checkversion(L);
	int i = 0;

	luaL_newmetatable(L, "signalfd");
	lua_pushcfunction(L, l_signalfd_close);
	lua_setfield(L, -2, "__gc");
	lua_createtable(L, 0, 1);
	{
		lua_pushcfunction(L, l_signalfd_getfd);
		lua_setfield(L, -2, "getfd");
		lua_pushcfunction(L, l_signalfd_read);
		lua_setfield(L, -2, "read");
		lua_pushcfunction(L, l_signalfd_close);
		lua_setfield(L, -2, "close");
	}
	lua_setfield(L, -2, "__index");
	lua_pop(L, 1);

	/* add the library */
	lua_newtable(L);
	luaL_setfuncs(L, lsignal_lib, 0);

	/* push lua_signals table into the registry */
	/* put the signals inside the library table too,
	 * they are only a reference */
	lua_pushstring(L, LUA_SIGNAL);
	lua_newtable(L);

	while(lua_signals[i].name != NULL) {
		/* registry table */
		lua_pushstring(L, lua_signals[i].name);
		lua_pushinteger(L, lua_signals[i].sig);
		lua_settable(L, -3);
		/* signal table */
		lua_pushstring(L, lua_signals[i].name);
		lua_pushinteger(L, lua_signals[i].sig);
		lua_settable(L, -5);
		i++;
	}

	/* add newtable to the registry */
	lua_settable(L, LUA_REGISTRYINDEX);

	return 1;
}
int luaopen_util_signal(lua_State *L) {
	return luaopen_prosody_util_signal(L);
}
