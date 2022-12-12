
/*
 * Lua polling library
 * Copyright (C) 2017-2022 Kim Alvefur
 *
 * This project is MIT licensed. Please see the
 * COPYING file in the source package for more information.
 *
 */

#include <unistd.h>
#include <string.h>
#include <errno.h>

#if defined(__linux__)
#define USE_EPOLL
#define POLL_BACKEND "epoll"
#elif defined(__unix__)
#define USE_POLL
#define POLL_BACKEND "poll"
#else
#define USE_SELECT
#define POLL_BACKEND "select"
#endif

#ifdef USE_EPOLL
#include <sys/epoll.h>
#ifndef MAX_EVENTS
#define MAX_EVENTS 64
#endif
#endif
#ifdef USE_POLL
#include <poll.h>
#ifndef MAX_EVENTS
#define MAX_EVENTS 10000
#endif
#endif
#ifdef USE_SELECT
#include <sys/select.h>
#endif

#include <lualib.h>
#include <lauxlib.h>

#define STATE_MT "util.poll<" POLL_BACKEND ">"

#if (LUA_VERSION_NUM < 504)
#define luaL_pushfail lua_pushnil
#endif

/*
 * Structure to keep state for each type of API
 */
typedef struct Lpoll_state {
	int processed;
#ifdef USE_EPOLL
	int epoll_fd;
	struct epoll_event events[MAX_EVENTS];
#endif
#ifdef USE_POLL
	nfds_t count;
	struct pollfd events[MAX_EVENTS];
#endif
#ifdef USE_SELECT
	fd_set wantread;
	fd_set wantwrite;
	fd_set readable;
	fd_set writable;
	fd_set all;
	fd_set err;
#endif
} Lpoll_state;

/*
 * Add an FD to be watched
 */
static int Ladd(lua_State *L) {
	struct Lpoll_state *state = luaL_checkudata(L, 1, STATE_MT);
	int fd = luaL_checkinteger(L, 2);

	int wantread = lua_toboolean(L, 3);
	int wantwrite = lua_toboolean(L, 4);

	if(fd < 0) {
		luaL_pushfail(L);
		lua_pushstring(L, strerror(EBADF));
		lua_pushinteger(L, EBADF);
		return 3;
	}

#ifdef USE_EPOLL
	struct epoll_event event;
	event.data.fd = fd;
	event.events = (wantread ? EPOLLIN : 0) | (wantwrite ? EPOLLOUT : 0);

	event.events |= EPOLLERR | EPOLLHUP | EPOLLRDHUP;

	int ret = epoll_ctl(state->epoll_fd, EPOLL_CTL_ADD, fd, &event);

	if(ret < 0) {
		ret = errno;
		luaL_pushfail(L);
		lua_pushstring(L, strerror(ret));
		lua_pushinteger(L, ret);
		return 3;
	}

	lua_pushboolean(L, 1);
	return 1;

#endif
#ifdef USE_POLL

	for(nfds_t i = 0; i < state->count; i++) {
		if(state->events[i].fd == fd) {
			luaL_pushfail(L);
			lua_pushstring(L, strerror(EEXIST));
			lua_pushinteger(L, EEXIST);
			return 3;
		}
	}

	if(state->count >= MAX_EVENTS) {
		luaL_pushfail(L);
		lua_pushstring(L, strerror(EMFILE));
		lua_pushinteger(L, EMFILE);
		return 3;
	}

	state->events[state->count].fd = fd;
	state->events[state->count].events = (wantread ? POLLIN : 0) | (wantwrite ? POLLOUT : 0);
	state->events[state->count].revents = 0;
	state->count++;

	lua_pushboolean(L, 1);
	return 1;
#endif
#ifdef USE_SELECT

	if(fd > FD_SETSIZE) {
		luaL_pushfail(L);
		lua_pushstring(L, strerror(EBADF));
		lua_pushinteger(L, EBADF);
		return 3;
	}

	if(FD_ISSET(fd, &state->all)) {
		luaL_pushfail(L);
		lua_pushstring(L, strerror(EEXIST));
		lua_pushinteger(L, EEXIST);
		return 3;
	}

	FD_CLR(fd, &state->readable);
	FD_CLR(fd, &state->writable);
	FD_CLR(fd, &state->err);

	FD_SET(fd, &state->all);

	if(wantread) {
		FD_SET(fd, &state->wantread);
	}
	else {
		FD_CLR(fd, &state->wantread);
	}

	if(wantwrite) {
		FD_SET(fd, &state->wantwrite);
	}
	else {
		FD_CLR(fd, &state->wantwrite);
	}

	lua_pushboolean(L, 1);
	return 1;
#endif
}

/*
 * Set events to watch for, readable and/or writable
 */
static int Lset(lua_State *L) {
	struct Lpoll_state *state = luaL_checkudata(L, 1, STATE_MT);
	int fd = luaL_checkinteger(L, 2);

#ifdef USE_EPOLL

	int wantread = lua_toboolean(L, 3);
	int wantwrite = lua_toboolean(L, 4);

	struct epoll_event event;
	event.data.fd = fd;
	event.events = (wantread ? EPOLLIN : 0) | (wantwrite ? EPOLLOUT : 0);

	event.events |= EPOLLERR | EPOLLHUP | EPOLLRDHUP;

	int ret = epoll_ctl(state->epoll_fd, EPOLL_CTL_MOD, fd, &event);

	if(ret == 0) {
		lua_pushboolean(L, 1);
		return 1;
	}
	else {
		ret = errno;
		luaL_pushfail(L);
		lua_pushstring(L, strerror(ret));
		lua_pushinteger(L, ret);
		return 3;
	}

#endif
#ifdef USE_POLL
	int wantread = lua_toboolean(L, 3);
	int wantwrite = lua_toboolean(L, 4);

	for(nfds_t i = 0; i < state->count; i++) {
		struct pollfd *event =  &state->events[i];

		if(event->fd == fd) {
			event->events = (wantread ? POLLIN : 0) | (wantwrite ? POLLOUT : 0);
			lua_pushboolean(L, 1);
			return 1;
		} else if(event->fd == -1) {
			break;
		}
	}

	luaL_pushfail(L);
	lua_pushstring(L, strerror(ENOENT));
	lua_pushinteger(L, ENOENT);
	return 3;
#endif
#ifdef USE_SELECT

	if(!FD_ISSET(fd, &state->all)) {
		luaL_pushfail(L);
		lua_pushstring(L, strerror(ENOENT));
		lua_pushinteger(L, ENOENT);
		return 3;
	}

	if(!lua_isnoneornil(L, 3)) {
		if(lua_toboolean(L, 3)) {
			FD_SET(fd, &state->wantread);
		}
		else {
			FD_CLR(fd, &state->wantread);
		}
	}

	if(!lua_isnoneornil(L, 4)) {
		if(lua_toboolean(L, 4)) {
			FD_SET(fd, &state->wantwrite);
		}
		else {
			FD_CLR(fd, &state->wantwrite);
		}
	}

	lua_pushboolean(L, 1);
	return 1;
#endif
}

/*
 * Remove FDs
 */
static int Ldel(lua_State *L) {
	struct Lpoll_state *state = luaL_checkudata(L, 1, STATE_MT);
	int fd = luaL_checkinteger(L, 2);

#ifdef USE_EPOLL

	struct epoll_event event;
	event.data.fd = fd;

	int ret = epoll_ctl(state->epoll_fd, EPOLL_CTL_DEL, fd, &event);

	if(ret == 0) {
		lua_pushboolean(L, 1);
		return 1;
	}
	else {
		ret = errno;
		luaL_pushfail(L);
		lua_pushstring(L, strerror(ret));
		lua_pushinteger(L, ret);
		return 3;
	}

#endif
#ifdef USE_POLL

	if(state->count == 0) {
		luaL_pushfail(L);
		lua_pushstring(L, strerror(ENOENT));
		lua_pushinteger(L, ENOENT);
		return 3;
	}

	/*
	 * Move the last item on top of the removed one
	 */
	struct pollfd *last = &state->events[state->count - 1];

	for(nfds_t i = 0; i < state->count; i++) {
		struct pollfd *event = &state->events[i];

		if(event->fd == fd) {
			event->fd = last->fd;
			event->events = last->events;
			event->revents = last->revents;
			last->fd = -1;
			state->count--;

			lua_pushboolean(L, 1);
			return 1;
		}
	}

	luaL_pushfail(L);
	lua_pushstring(L, strerror(ENOENT));
	lua_pushinteger(L, ENOENT);
	return 3;
#endif
#ifdef USE_SELECT

	if(!FD_ISSET(fd, &state->all)) {
		luaL_pushfail(L);
		lua_pushstring(L, strerror(ENOENT));
		lua_pushinteger(L, ENOENT);
		return 3;
	}

	FD_CLR(fd, &state->wantread);
	FD_CLR(fd, &state->wantwrite);
	FD_CLR(fd, &state->readable);
	FD_CLR(fd, &state->writable);
	FD_CLR(fd, &state->all);
	FD_CLR(fd, &state->err);

	lua_pushboolean(L, 1);
	return 1;
#endif
}


/*
 * Check previously manipulated event state for FDs ready for reading or writing
 */
static int Lpushevent(lua_State *L, struct Lpoll_state *state) {
#ifdef USE_EPOLL

	if(state->processed > 0) {
		state->processed--;
		struct epoll_event event = state->events[state->processed];
		lua_pushinteger(L, event.data.fd);
		lua_pushboolean(L, event.events & (EPOLLIN | EPOLLHUP | EPOLLRDHUP | EPOLLERR));
		lua_pushboolean(L, event.events & EPOLLOUT);
		return 3;
	}

#endif
#ifdef USE_POLL

	for(int i = state->processed - 1; i >= 0; i--) {
		struct pollfd *event = &state->events[i];

		if(event->fd != -1 && event->revents != 0) {
			lua_pushinteger(L, event->fd);
			lua_pushboolean(L, event->revents & (POLLIN | POLLHUP | POLLERR));
			lua_pushboolean(L, event->revents & POLLOUT);
			event->revents = 0;
			state->processed = i;
			return 3;
		}
	}

#endif
#ifdef USE_SELECT

	for(int fd = state->processed + 1; fd < FD_SETSIZE; fd++) {
		if(FD_ISSET(fd, &state->readable) || FD_ISSET(fd, &state->writable) || FD_ISSET(fd, &state->err)) {
			lua_pushinteger(L, fd);
			lua_pushboolean(L, FD_ISSET(fd, &state->readable) | FD_ISSET(fd, &state->err));
			lua_pushboolean(L, FD_ISSET(fd, &state->writable));
			FD_CLR(fd, &state->readable);
			FD_CLR(fd, &state->writable);
			FD_CLR(fd, &state->err);
			state->processed = fd;
			return 3;
		}
	}

#endif
	return 0;
}

/*
 * Wait for event
 */
static int Lwait(lua_State *L) {
	struct Lpoll_state *state = luaL_checkudata(L, 1, STATE_MT);

	int ret = Lpushevent(L, state);

	if(ret != 0) {
		return ret;
	}

	lua_Number timeout = luaL_checknumber(L, 2);
	luaL_argcheck(L, timeout >= 0, 1, "positive number expected");

#ifdef USE_EPOLL
	ret = epoll_wait(state->epoll_fd, state->events, MAX_EVENTS, timeout * 1000);
#endif
#ifdef USE_POLL
	ret = poll(state->events, state->count, timeout * 1000);
#endif
#ifdef USE_SELECT
	/*
	 * select(2) mutates the fd_sets passed to it so in order to not
	 * have to recreate it manually every time a copy is made.
	 */
	memcpy(&state->readable, &state->wantread, sizeof(fd_set));
	memcpy(&state->writable, &state->wantwrite, sizeof(fd_set));
	memcpy(&state->err, &state->all, sizeof(fd_set));

	struct timeval tv;
	tv.tv_sec = (time_t)timeout;
	tv.tv_usec = ((suseconds_t)(timeout * 1000000)) % 1000000;

	ret = select(FD_SETSIZE, &state->readable, &state->writable, &state->err, &tv);
#endif

	if(ret == 0) {
		/* Is this an error? */
		lua_pushnil(L);
		lua_pushstring(L, "timeout");
		return 2;
	}
	else if(ret < 0 && errno == EINTR) {
		/* Is this an error? */
		lua_pushnil(L);
		lua_pushstring(L, "signal");
		return 2;
	}
	else if(ret < 0) {
		ret = errno;
		luaL_pushfail(L);
		lua_pushstring(L, strerror(ret));
		lua_pushinteger(L, ret);
		return 3;
	}

	/*
	 * Search for the first ready FD and return it
	 */
#ifdef USE_EPOLL
	state->processed = ret;
#endif
#ifdef USE_POLL
	state->processed = state->count;
#endif
#ifdef USE_SELECT
	state->processed = -1;
#endif
	return Lpushevent(L, state);
}

#ifdef USE_EPOLL
/*
 * Return Epoll FD
 */
static int Lgetfd(lua_State *L) {
	struct Lpoll_state *state = luaL_checkudata(L, 1, STATE_MT);
	lua_pushinteger(L, state->epoll_fd);
	return 1;
}

/*
 * Close epoll FD
 */
static int Lgc(lua_State *L) {
	struct Lpoll_state *state = luaL_checkudata(L, 1, STATE_MT);

	if(state->epoll_fd == -1) {
		return 0;
	}

	if(close(state->epoll_fd) == 0) {
		state->epoll_fd = -1;
	}
	else {
		lua_pushstring(L, strerror(errno));
		lua_error(L);
	}

	return 0;
}
#endif

/*
 * String representation
 */
static int Ltos(lua_State *L) {
	struct Lpoll_state *state = luaL_checkudata(L, 1, STATE_MT);
	lua_pushfstring(L, "%s: %p", STATE_MT, state);
	return 1;
}

/*
 * Create a new context
 */
static int Lnew(lua_State *L) {
	/* Allocate state */
	Lpoll_state *state = lua_newuserdata(L, sizeof(Lpoll_state));
	luaL_setmetatable(L, STATE_MT);

	/* Initialize state */
#ifdef USE_EPOLL
	state->epoll_fd = -1;
	state->processed = 0;

	int epoll_fd = epoll_create1(EPOLL_CLOEXEC);

	if(epoll_fd <= 0) {
		luaL_pushfail(L);
		lua_pushstring(L, strerror(errno));
		lua_pushinteger(L, errno);
		return 3;
	}

	state->epoll_fd = epoll_fd;
#endif
#ifdef USE_POLL
	state->processed = -1;
	state->count = 0;

	for(nfds_t i = 0; i < MAX_EVENTS; i++) {
		state->events[i].fd = -1;
		state->events[i].events = 0;
		state->events[i].revents = 0;
	}

#endif
#ifdef USE_SELECT
	FD_ZERO(&state->wantread);
	FD_ZERO(&state->wantwrite);
	FD_ZERO(&state->readable);
	FD_ZERO(&state->writable);
	FD_ZERO(&state->all);
	FD_ZERO(&state->err);
	state->processed = FD_SETSIZE;
#endif

	return 1;
}

/*
 * Open library
 */
int luaopen_util_poll(lua_State *L) {
	luaL_checkversion(L);

	luaL_newmetatable(L, STATE_MT);
	{

		lua_pushliteral(L, STATE_MT);
		lua_setfield(L, -2, "__name");

		lua_pushcfunction(L, Ltos);
		lua_setfield(L, -2, "__tostring");

		lua_createtable(L, 0, 2);
		{
			lua_pushcfunction(L, Ladd);
			lua_setfield(L, -2, "add");
			lua_pushcfunction(L, Lset);
			lua_setfield(L, -2, "set");
			lua_pushcfunction(L, Ldel);
			lua_setfield(L, -2, "del");
			lua_pushcfunction(L, Lwait);
			lua_setfield(L, -2, "wait");
#ifdef USE_EPOLL
			lua_pushcfunction(L, Lgetfd);
			lua_setfield(L, -2, "getfd");
#endif
		}
		lua_setfield(L, -2, "__index");

#ifdef USE_EPOLL
		lua_pushcfunction(L, Lgc);
		lua_setfield(L, -2, "__gc");
#endif
	}

	lua_createtable(L, 0, 3);
	{
		lua_pushcfunction(L, Lnew);
		lua_setfield(L, -2, "new");

#define push_errno(named_error) lua_pushinteger(L, named_error);\
		lua_setfield(L, -2, #named_error);

		push_errno(EEXIST);
		push_errno(EMFILE);
		push_errno(ENOENT);

		lua_pushliteral(L, POLL_BACKEND);
		lua_setfield(L, -2, "api");

	}
	return 1;
}

