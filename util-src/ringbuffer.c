
#include <stdlib.h>
#include <unistd.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>

#if (LUA_VERSION_NUM < 504)
#define luaL_pushfail lua_pushnil
#endif

typedef struct {
	size_t rpos; /* read position */
	size_t wpos; /* write position */
	size_t alen; /* allocated size */
	size_t blen; /* current content size */
	char buffer[];
} ringbuffer;

/* Translate absolute idx to a wrapped index within the buffer,
   based on current read position */
static int wrap_pos(const ringbuffer *b, const long idx, long *pos) {
	if(idx > (long)b->blen) {
		return 0;
	}
	if(idx + (long)b->rpos > (long)b->alen) {
		*pos = idx - (b->alen - b->rpos);
	} else {
		*pos = b->rpos + idx;
	}
	return 1;
}

static int calc_splice_positions(const ringbuffer *b, long start, long end, long *out_start, long *out_end) {
	if(start < 0) {
		start = 1 + start + b->blen;
	}
	if(start <= 0) {
		start = 1;
	}

	if(end < 0) {
		end = 1 + end + b->blen;
	}

	if(end > (long)b->blen) {
		end = b->blen;
	}
	if(start < 1) {
		start = 1;
	}

	if(start > end) {
		return 0;
	}

	start = start - 1;

	if(!wrap_pos(b, start, out_start)) {
		return 0;
	}
	if(!wrap_pos(b, end, out_end)) {
		return 0;
	}

	return 1;
}

static void writechar(ringbuffer *b, char c) {
	b->blen++;
	b->buffer[(b->wpos++) % b->alen] = c;
}

/* make sure position counters stay within the allocation */
static void modpos(ringbuffer *b) {
	b->rpos = b->rpos % b->alen;
	b->wpos = b->wpos % b->alen;
}

static int find(ringbuffer *b, const char *s, size_t l) {
	size_t i, j;
	int m;

	if(b->rpos == b->wpos) { /* empty */
		return 0;
	}

	/* look for a matching first byte */
	for(i = 0; i <= b->blen - l; i++) {
		if(b->buffer[(b->rpos + i) % b->alen] == *s) {
			m = 1;

			/* check if the following byte also match */
			for(j = 1; j < l; j++)
				if(b->buffer[(b->rpos + i + j) % b->alen] != s[j]) {
					m = 0;
					break;
				}

			if(m) {
				return i + l;
			}
		}
	}

	return 0;
}

/*
 * Find first position of a substring in buffer
 * (buffer, string) -> number
 */
static int rb_find(lua_State *L) {
	size_t l, m;
	ringbuffer *b = luaL_checkudata(L, 1, "ringbuffer_mt");
	const char *s = luaL_checklstring(L, 2, &l);
	m = find(b, s, l);

	if(m > 0) {
		lua_pushinteger(L, m);
		return 1;
	}

	return 0;
}

/*
 * Move read position forward without returning the data
 * (buffer, number) -> boolean
 */
static int rb_discard(lua_State *L) {
	ringbuffer *b = luaL_checkudata(L, 1, "ringbuffer_mt");
	size_t r = luaL_checkinteger(L, 2);

	if(r > b->blen) {
		lua_pushboolean(L, 0);
		return 1;
	}

	b->blen -= r;
	b->rpos += r;
	modpos(b);

	lua_pushboolean(L, 1);
	return 1;
}

/*
 * Read bytes from buffer
 * (buffer, number, boolean?) -> string
 */
static int rb_read(lua_State *L) {
	ringbuffer *b = luaL_checkudata(L, 1, "ringbuffer_mt");
	size_t r = luaL_checkinteger(L, 2);
	int peek = lua_toboolean(L, 3);

	if(r > b->blen) {
		luaL_pushfail(L);
		return 1;
	}

	if((b->rpos + r) > b->alen) {
		/* Substring wraps around to the beginning of the buffer */
		lua_pushlstring(L, &b->buffer[b->rpos], b->alen - b->rpos);
		lua_pushlstring(L, b->buffer, r - (b->alen - b->rpos));
		lua_concat(L, 2);
	} else {
		lua_pushlstring(L, &b->buffer[b->rpos], r);
	}

	if(!peek) {
		b->blen -= r;
		b->rpos += r;
		modpos(b);
	}

	return 1;
}

/*
 * Read buffer until first occurrence of a substring
 * (buffer, string) -> string
 */
static int rb_readuntil(lua_State *L) {
	size_t l, m;
	ringbuffer *b = luaL_checkudata(L, 1, "ringbuffer_mt");
	const char *s = luaL_checklstring(L, 2, &l);
	m = find(b, s, l);

	if(m > 0) {
		lua_settop(L, 1);
		lua_pushinteger(L, m);
		return rb_read(L);
	}

	return 0;
}

/*
 * Write bytes into the buffer
 * (buffer, string) -> integer
 */
static int rb_write(lua_State *L) {
	size_t l, w = 0;
	ringbuffer *b = luaL_checkudata(L, 1, "ringbuffer_mt");
	const char *s = luaL_checklstring(L, 2, &l);

	/* Does `l` bytes fit? */
	if((l + b->blen) > b->alen) {
		luaL_pushfail(L);
		return 1;
	}

	while(l-- > 0) {
		writechar(b, *s++);
		w++;
	}

	modpos(b);

	lua_pushinteger(L, w);

	return 1;
}

static int rb_tostring(lua_State *L) {
	ringbuffer *b = luaL_checkudata(L, 1, "ringbuffer_mt");
	lua_pushfstring(L, "ringbuffer: %p %d/%d", b, b->blen, b->alen);
	return 1;
}

static int rb_sub(lua_State *L) {
	ringbuffer *b = luaL_checkudata(L, 1, "ringbuffer_mt");

	long start = luaL_checkinteger(L, 2);
	long end = luaL_optinteger(L, 3, -1);

	long wrapped_start, wrapped_end;
	if(!calc_splice_positions(b, start, end, &wrapped_start, &wrapped_end)) {
		lua_pushstring(L, "");
	} else if(wrapped_end <= wrapped_start) {
		lua_pushlstring(L, &b->buffer[wrapped_start], b->alen - wrapped_start);
		lua_pushlstring(L, b->buffer, wrapped_end);
		lua_concat(L, 2);
	} else {
		lua_pushlstring(L, &b->buffer[wrapped_start], (wrapped_end - wrapped_start));
	}

	return 1;
}

static int rb_byte(lua_State *L) {
	ringbuffer *b = luaL_checkudata(L, 1, "ringbuffer_mt");

	long start = luaL_optinteger(L, 2, 1);
	long end = luaL_optinteger(L, 3, start);

	long i;

	long wrapped_start, wrapped_end;
	if(calc_splice_positions(b, start, end, &wrapped_start, &wrapped_end)) {
		if(wrapped_end <= wrapped_start) {
			for(i = wrapped_start; i < (long)b->alen; i++) {
				lua_pushinteger(L, (unsigned char)b->buffer[i]);
			}
			for(i = 0; i < wrapped_end; i++) {
				lua_pushinteger(L, (unsigned char)b->buffer[i]);
			}
			return wrapped_end + (b->alen - wrapped_start);
		} else {
			for(i = wrapped_start; i < wrapped_end; i++) {
				lua_pushinteger(L, (unsigned char)b->buffer[i]);
			}
			return wrapped_end - wrapped_start;
		}
	}

	return 0;
}

static int rb_length(lua_State *L) {
	ringbuffer *b = luaL_checkudata(L, 1, "ringbuffer_mt");
	lua_pushinteger(L, b->blen);
	return 1;
}

static int rb_size(lua_State *L) {
	ringbuffer *b = luaL_checkudata(L, 1, "ringbuffer_mt");
	lua_pushinteger(L, b->alen);
	return 1;
}

static int rb_free(lua_State *L) {
	ringbuffer *b = luaL_checkudata(L, 1, "ringbuffer_mt");
	lua_pushinteger(L, b->alen - b->blen);
	return 1;
}

static int rb_new(lua_State *L) {
	lua_Integer size = luaL_optinteger(L, 1, sysconf(_SC_PAGESIZE));
	luaL_argcheck(L, size > 0, 1, "positive integer expected");
	ringbuffer *b = lua_newuserdata(L, sizeof(ringbuffer) + size);

	b->rpos = 0;
	b->wpos = 0;
	b->alen = size;
	b->blen = 0;

	luaL_getmetatable(L, "ringbuffer_mt");
	lua_setmetatable(L, -2);

	return 1;
}

int luaopen_prosody_util_ringbuffer(lua_State *L) {
	luaL_checkversion(L);

	if(luaL_newmetatable(L, "ringbuffer_mt")) {
		lua_pushcfunction(L, rb_tostring);
		lua_setfield(L, -2, "__tostring");
		lua_pushcfunction(L, rb_length);
		lua_setfield(L, -2, "__len");

		lua_createtable(L, 0, 7); /* __index */
		{
			lua_pushcfunction(L, rb_find);
			lua_setfield(L, -2, "find");
			lua_pushcfunction(L, rb_discard);
			lua_setfield(L, -2, "discard");
			lua_pushcfunction(L, rb_read);
			lua_setfield(L, -2, "read");
			lua_pushcfunction(L, rb_readuntil);
			lua_setfield(L, -2, "readuntil");
			lua_pushcfunction(L, rb_write);
			lua_setfield(L, -2, "write");
			lua_pushcfunction(L, rb_size);
			lua_setfield(L, -2, "size");
			lua_pushcfunction(L, rb_length);
			lua_setfield(L, -2, "length");
			lua_pushcfunction(L, rb_sub);
			lua_setfield(L, -2, "sub");
			lua_pushcfunction(L, rb_byte);
			lua_setfield(L, -2, "byte");
			lua_pushcfunction(L, rb_free);
			lua_setfield(L, -2, "free");
		}
		lua_setfield(L, -2, "__index");
	}

	lua_createtable(L, 0, 1);
	lua_pushcfunction(L, rb_new);
	lua_setfield(L, -2, "new");
	return 1;
}

int luaopen_util_ringbuffer(lua_State *L) {
	return luaopen_prosody_util_ringbuffer(L);
}
