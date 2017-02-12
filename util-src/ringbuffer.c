
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>

#include <lua.h>
#include <lauxlib.h>

typedef struct {
	size_t rpos; /* read position */
	size_t wpos; /* write position */
	size_t alen; /* allocated size */
	size_t blen; /* current content size */
	char buffer[];
} ringbuffer;

char readchar(ringbuffer* b) {
	b->blen--;
	return b->buffer[(b->rpos++) % b->alen];
}

void writechar(ringbuffer* b, char c) {
	b->blen++;
	b->buffer[(b->wpos++) % b->alen] = c;
}

/* make sure position counters stay within the allocation */
void modpos(ringbuffer* b) {
	b->rpos = b->rpos % b->alen;
	b->wpos = b->wpos % b->alen;
}

int find(ringbuffer* b, const char* s, int l) {
	size_t i, j;
	int m;

	if(b->rpos == b->wpos) { /* empty */
		return 0;
	}

	for(i = 0; i <= b->blen - l; i++) {
		if(b->buffer[(b->rpos + i) % b->alen] == *s) {
			m = 1;

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

int rb_find(lua_State* L) {
	size_t l, m;
	ringbuffer* b = luaL_checkudata(L, 1, "ringbuffer_mt");
	const char* s = luaL_checklstring(L, 2, &l);
	m = find(b, s, l);

	if(m > 0) {
		lua_pushinteger(L, m);
		return 1;
	}

	return 0;
}

int rb_read(lua_State* L) {
	ringbuffer* b = luaL_checkudata(L, 1, "ringbuffer_mt");
	int r = luaL_checkinteger(L, 2);
	int peek = lua_toboolean(L, 3);

	if(r > b->blen) {
		lua_pushnil(L);
		return 1;
	}

	if((b->rpos + r) > b->alen) {
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

int rb_readuntil(lua_State* L) {
	size_t l, m;
	ringbuffer* b = luaL_checkudata(L, 1, "ringbuffer_mt");
	const char* s = luaL_checklstring(L, 2, &l);
	m = find(b, s, l);

	if(m > 0) {
		lua_settop(L, 1);
		lua_pushinteger(L, m);
		return rb_read(L);
	}

	return 0;
}

int rb_write(lua_State* L) {
	size_t l, w = 0;
	ringbuffer* b = luaL_checkudata(L, 1, "ringbuffer_mt");
	const char* s = luaL_checklstring(L, 2, &l);

	/* Does `l` bytes fit? */
	if((l + b->blen) > b->alen) {
		lua_pushnil(L);
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

int rb_tostring(lua_State* L) {
	ringbuffer* b = luaL_checkudata(L, 1, "ringbuffer_mt");
	lua_pushfstring(L, "ringbuffer: %p %d/%d", b, b->blen, b->alen);
	return 1;
}

int rb_length(lua_State* L) {
	ringbuffer* b = luaL_checkudata(L, 1, "ringbuffer_mt");
	lua_pushinteger(L, b->blen);
	return 1;
}

int rb_size(lua_State* L) {
	ringbuffer* b = luaL_checkudata(L, 1, "ringbuffer_mt");
	lua_pushinteger(L, b->alen);
	return 1;
}

int rb_free(lua_State* L) {
	ringbuffer* b = luaL_checkudata(L, 1, "ringbuffer_mt");
	lua_pushinteger(L, b->alen - b->blen);
	return 1;
}

int rb_new(lua_State* L) {
	size_t size = luaL_optinteger(L, 1, sysconf(_SC_PAGESIZE));
	ringbuffer *b = lua_newuserdata(L, sizeof(ringbuffer) + size);

	b->rpos = 0;
	b->wpos = 0;
	b->alen = size;
	b->blen = 0;

	luaL_getmetatable(L, "ringbuffer_mt");
	lua_setmetatable(L, -2);

	return 1;
}

int luaopen_util_ringbuffer(lua_State* L) {
#if (LUA_VERSION_NUM > 501)
	luaL_checkversion(L);
#endif
	if(luaL_newmetatable(L, "ringbuffer_mt")) {
		lua_pushcfunction(L, rb_tostring);
		lua_setfield(L, -2, "__tostring");
		lua_pushcfunction(L, rb_length);
		lua_setfield(L, -2, "__len");

		lua_newtable(L); /* __index */
		{
			lua_pushcfunction(L, rb_find);
			lua_setfield(L, -2, "find");
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
			lua_pushcfunction(L, rb_free);
			lua_setfield(L, -2, "free");
		}
		lua_setfield(L, -2, "__index");
	}

	lua_newtable(L);
	lua_pushcfunction(L, rb_new);
	lua_setfield(L, -2, "new");
	return 1;
}
