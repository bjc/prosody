/* Prosody IM v0.4
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
*/

/*
* encodings.c
* Lua library for base64, stringprep and idna encodings
*/

// Newer MSVC compilers deprecate strcpy as unsafe, but we use it in a safe way
#define _CRT_SECURE_NO_DEPRECATE

#include <string.h>
#include <stdlib.h>

#include "lua.h"
#include "lauxlib.h"

/***************** BASE64 *****************/

static const char code[]=
"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void base64_encode(luaL_Buffer *b, unsigned int c1, unsigned int c2, unsigned int c3, int n)
{
	unsigned long tuple=c3+256UL*(c2+256UL*c1);
	int i;
	char s[4];
	for (i=0; i<4; i++) {
		s[3-i] = code[tuple % 64];
		tuple /= 64;
	}
	for (i=n+1; i<4; i++) s[i]='=';
	luaL_addlstring(b,s,4);
}

static int Lbase64_encode(lua_State *L)		/** encode(s) */
{
	size_t l;
	const unsigned char *s=(const unsigned char*)luaL_checklstring(L,1,&l);
	luaL_Buffer b;
	int n;
	luaL_buffinit(L,&b);
	for (n=l/3; n--; s+=3) base64_encode(&b,s[0],s[1],s[2],3);
	switch (l%3)
	{
		case 1: base64_encode(&b,s[0],0,0,1);		break;
		case 2: base64_encode(&b,s[0],s[1],0,2);		break;
	}
	luaL_pushresult(&b);
	return 1;
}

static void base64_decode(luaL_Buffer *b, int c1, int c2, int c3, int c4, int n)
{
	unsigned long tuple=c4+64L*(c3+64L*(c2+64L*c1));
	char s[3];
	switch (--n)
	{
		case 3: s[2]=(char) tuple;
		case 2: s[1]=(char) (tuple >> 8);
		case 1: s[0]=(char) (tuple >> 16);
	}
	luaL_addlstring(b,s,n);
}

static int Lbase64_decode(lua_State *L)		/** decode(s) */
{
	size_t l;
	const char *s=luaL_checklstring(L,1,&l);
	luaL_Buffer b;
	int n=0;
	char t[4];
	luaL_buffinit(L,&b);
	for (;;)
	{
		int c=*s++;
		switch (c)
		{
			const char *p;
			default:
				p=strchr(code,c); if (p==NULL) return 0;
				t[n++]= (char) (p-code);
				if (n==4)
				{
					base64_decode(&b,t[0],t[1],t[2],t[3],4);
					n=0;
				}
				break;
			case '=':
				switch (n)
				{
					case 1: base64_decode(&b,t[0],0,0,0,1);		break;
					case 2: base64_decode(&b,t[0],t[1],0,0,2);	break;
					case 3: base64_decode(&b,t[0],t[1],t[2],0,3);	break;
				}
				n=0;
				break;
			case 0:
				luaL_pushresult(&b);
				return 1;
			case '\n': case '\r': case '\t': case ' ': case '\f': case '\b':
				break;
		}
	}
}

static const luaL_Reg Reg_base64[] =
{
	{ "encode",	Lbase64_encode	},
	{ "decode",	Lbase64_decode	},
	{ NULL,		NULL	}
};

/***************** STRINGPREP *****************/

#include <stringprep.h>

static int stringprep_prep(lua_State *L, const Stringprep_profile *profile)
{
	size_t len;
	const char *s;
	char string[1024];
	int ret;
	if(!lua_isstring(L, 1)) {
		lua_pushnil(L);
		return 1;
	}
	s = lua_tolstring(L, 1, &len);
	if (len >= 1024) {
		lua_pushnil(L);
		return 1; // TODO return error message
	}
	strcpy(string, s);
	ret = stringprep(string, 1024, 0, profile);
	if (ret == STRINGPREP_OK) {
		lua_pushstring(L, string);
		return 1;
	} else {
		lua_pushnil(L);
		return 1; // TODO return error message
	}
}

#define MAKE_PREP_FUNC(myFunc, prep) \
static int myFunc(lua_State *L) { return stringprep_prep(L, prep); }

MAKE_PREP_FUNC(Lstringprep_nameprep, stringprep_nameprep)		/** stringprep.nameprep(s) */
MAKE_PREP_FUNC(Lstringprep_nodeprep, stringprep_xmpp_nodeprep)		/** stringprep.nodeprep(s) */
MAKE_PREP_FUNC(Lstringprep_resourceprep, stringprep_xmpp_resourceprep)		/** stringprep.resourceprep(s) */
MAKE_PREP_FUNC(Lstringprep_saslprep, stringprep_saslprep)		/** stringprep.saslprep(s) */

static const luaL_Reg Reg_stringprep[] =
{
	{ "nameprep",	Lstringprep_nameprep	},
	{ "nodeprep",	Lstringprep_nodeprep	},
	{ "resourceprep",	Lstringprep_resourceprep	},
	{ "saslprep",	Lstringprep_saslprep	},
	{ NULL,		NULL	}
};

/***************** IDNA *****************/

#include <idna.h>
#include <idn-free.h>

static int Lidna_to_ascii(lua_State *L)		/** idna.to_ascii(s) */
{
	size_t len;
	const char *s = luaL_checklstring(L, 1, &len);
	char* output = NULL;
	int ret = idna_to_ascii_8z(s, &output, IDNA_USE_STD3_ASCII_RULES);
	if (ret == IDNA_SUCCESS) {
		lua_pushstring(L, output);
		idn_free(output);
		return 1;
	} else {
		lua_pushnil(L);
		idn_free(output);
		return 1; // TODO return error message
	}
}

static int Lidna_to_unicode(lua_State *L)		/** idna.to_unicode(s) */
{
	size_t len;
	const char *s = luaL_checklstring(L, 1, &len);
	char* output = NULL;
	int ret = idna_to_unicode_8z8z(s, &output, 0);
	if (ret == IDNA_SUCCESS) {
		lua_pushstring(L, output);
		idn_free(output);
		return 1;
	} else {
		lua_pushnil(L);
		idn_free(output);
		return 1; // TODO return error message
	}
}

static const luaL_Reg Reg_idna[] =
{
	{ "to_ascii",	Lidna_to_ascii	},
	{ "to_unicode",	Lidna_to_unicode	},
	{ NULL,		NULL	}
};

/***************** end *****************/

static const luaL_Reg Reg[] =
{
	{ NULL,		NULL	}
};

LUALIB_API int luaopen_util_encodings(lua_State *L)
{
	luaL_register(L, "encodings", Reg);

	lua_pushliteral(L, "base64");
	lua_newtable(L);
	luaL_register(L, NULL, Reg_base64);
	lua_settable(L,-3);

	lua_pushliteral(L, "stringprep");
	lua_newtable(L);
	luaL_register(L, NULL, Reg_stringprep);
	lua_settable(L,-3);

	lua_pushliteral(L, "idna");
	lua_newtable(L);
	luaL_register(L, NULL, Reg_idna);
	lua_settable(L,-3);

	lua_pushliteral(L, "version");			/** version */
	lua_pushliteral(L, "-3.14");
	lua_settable(L,-3);
	return 1;
}
