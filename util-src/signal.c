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

#define _GNU_SOURCE

#include <signal.h>
#include <stdlib.h>

#include "lua.h"
#include "lauxlib.h"

#if (LUA_VERSION_NUM == 501)
#define luaL_setfuncs(L, R, N) luaL_register(L, NULL, R)
#endif

#ifndef lsig

#define lsig

struct lua_signal {
	char *name; /* name of the signal */
	int sig; /* the signal */
};

#endif

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

static struct signal_event {
	int Nsig;
	struct signal_event *next_event;
} *signal_queue = NULL;

static struct signal_event *last_event = NULL;

static void sighook(lua_State *L, lua_Debug *ar) {
	struct signal_event *event;
	/* restore the old hook */
	lua_sethook(L, Hsig, Hmask, Hcount);

	lua_pushstring(L, LUA_SIGNAL);
	lua_gettable(L, LUA_REGISTRYINDEX);

	while((event = signal_queue)) {
		lua_pushnumber(L, event->Nsig);
		lua_gettable(L, -2);
		lua_call(L, 0, 0);
		signal_queue = event->next_event;
		free(event);
	};

	lua_pop(L, 1); /* pop lua_signal table */

}

static void handle(int sig) {
	if(!signal_queue) {
		/* Store the existing debug hook (if any) and its parameters */
		Hsig = lua_gethook(Lsig);
		Hmask = lua_gethookmask(Lsig);
		Hcount = lua_gethookcount(Lsig);

		signal_queue = malloc(sizeof(struct signal_event));
		signal_queue->Nsig = sig;
		signal_queue->next_event = NULL;

		last_event = signal_queue;

		/* Set our new debug hook */
		lua_sethook(Lsig, sighook, LUA_MASKCALL | LUA_MASKRET | LUA_MASKCOUNT, 1);
	} else {
		last_event->next_event = malloc(sizeof(struct signal_event));
		last_event->next_event->Nsig = sig;
		last_event->next_event->next_event = NULL;

		last_event = last_event->next_event;
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
		sig = (int) lua_tonumber(L, 1);
	} else if(t == LUA_TSTRING) {
		lua_pushstring(L, LUA_SIGNAL);
		lua_gettable(L, LUA_REGISTRYINDEX);
		lua_pushvalue(L, 1);
		lua_gettable(L, -2);

		if(!lua_isnumber(L, -1)) {
			return luaL_error(L, "invalid signal string");
		}

		sig = (int) lua_tonumber(L, -1);
		lua_pop(L, 1); /* get rid of number we pushed */
	} else {
		luaL_checknumber(L, 1);    /* will always error, with good error msg */
		return luaL_error(L, "unreachable: invalid number was accepted");
	}

	/* set handler */
	if(args == 1 || lua_isnil(L, 2)) { /* clear handler */
		lua_pushstring(L, LUA_SIGNAL);
		lua_gettable(L, LUA_REGISTRYINDEX);
		lua_pushnumber(L, sig);
		lua_gettable(L, -2); /* return old handler */
		lua_pushnumber(L, sig);
		lua_pushnil(L);
		lua_settable(L, -4);
		lua_remove(L, -2); /* remove LUA_SIGNAL table */
		signal(sig, SIG_DFL);
	} else {
		luaL_checktype(L, 2, LUA_TFUNCTION);

		lua_pushstring(L, LUA_SIGNAL);
		lua_gettable(L, LUA_REGISTRYINDEX);

		lua_pushnumber(L, sig);
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
	lua_Number ret;

	luaL_checkany(L, 1);

	t = lua_type(L, 1);

	if(t == LUA_TNUMBER) {
		ret = (lua_Number) raise((int) lua_tonumber(L, 1));
		lua_pushnumber(L, ret);
	} else if(t == LUA_TSTRING) {
		lua_pushstring(L, LUA_SIGNAL);
		lua_gettable(L, LUA_REGISTRYINDEX);
		lua_pushvalue(L, 1);
		lua_gettable(L, -2);

		if(!lua_isnumber(L, -1)) {
			return luaL_error(L, "invalid signal string");
		}

		ret = (lua_Number) raise((int) lua_tonumber(L, -1));
		lua_pop(L, 1); /* get rid of number we pushed */
		lua_pushnumber(L, ret);
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
	lua_Number ret; /* return value */

	luaL_checknumber(L, 1); /* must be int for pid */
	luaL_checkany(L, 2); /* check for a second arg */

	t = lua_type(L, 2);

	if(t == LUA_TNUMBER) {
		ret = (lua_Number) kill((int) lua_tonumber(L, 1),
		                        (int) lua_tonumber(L, 2));
		lua_pushnumber(L, ret);
	} else if(t == LUA_TSTRING) {
		lua_pushstring(L, LUA_SIGNAL);
		lua_gettable(L, LUA_REGISTRYINDEX);
		lua_pushvalue(L, 2);
		lua_gettable(L, -2);

		if(!lua_isnumber(L, -1)) {
			return luaL_error(L, "invalid signal string");
		}

		ret = (lua_Number) kill((int) lua_tonumber(L, 1),
		                        (int) lua_tonumber(L, -1));
		lua_pop(L, 1); /* get rid of number we pushed */
		lua_pushnumber(L, ret);
	} else {
		luaL_checknumber(L, 2);    /* will always error, with good error msg */
	}

	return 1;
}

#endif

static const struct luaL_Reg lsignal_lib[] = {
	{"signal", l_signal},
	{"raise", l_raise},
#if defined(__unix__) || defined(__APPLE__)
	{"kill", l_kill},
#endif
	{NULL, NULL}
};

int luaopen_util_signal(lua_State *L) {
#if (LUA_VERSION_NUM > 501)
	luaL_checkversion(L);
#endif
	int i = 0;

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
		lua_pushnumber(L, lua_signals[i].sig);
		lua_settable(L, -3);
		/* signal table */
		lua_pushstring(L, lua_signals[i].name);
		lua_pushnumber(L, lua_signals[i].sig);
		lua_settable(L, -5);
		i++;
	}

	/* add newtable to the registry */
	lua_settable(L, LUA_REGISTRYINDEX);

	return 1;
}
