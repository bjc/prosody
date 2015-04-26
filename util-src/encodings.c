/* Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 1994-2015 Lua.org, PUC-Rio.
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
*/

/*
* encodings.c
* Lua library for base64, stringprep and idna encodings
*/

/* Newer MSVC compilers deprecate strcpy as unsafe, but we use it in a safe way */
#define _CRT_SECURE_NO_DEPRECATE

#include <string.h>
#include <stdlib.h>
#include "lua.h"
#include "lauxlib.h"

#if (LUA_VERSION_NUM == 501)
#define luaL_setfuncs(L, R, N) luaL_register(L, NULL, R)
#endif

/***************** BASE64 *****************/

static const char code[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void base64_encode(luaL_Buffer* b, unsigned int c1, unsigned int c2, unsigned int c3, int n) {
	unsigned long tuple = c3 + 256UL * (c2 + 256UL * c1);
	int i;
	char s[4];

	for(i = 0; i < 4; i++) {
		s[3 - i] = code[tuple % 64];
		tuple /= 64;
	}

	for(i = n + 1; i < 4; i++) {
		s[i] = '=';
	}

	luaL_addlstring(b, s, 4);
}

static int Lbase64_encode(lua_State* L) {	/** encode(s) */
	size_t l;
	const unsigned char* s = (const unsigned char*)luaL_checklstring(L, 1, &l);
	luaL_Buffer b;
	int n;
	luaL_buffinit(L, &b);

	for(n = l / 3; n--; s += 3) {
		base64_encode(&b, s[0], s[1], s[2], 3);
	}

	switch(l % 3) {
		case 1:
			base64_encode(&b, s[0], 0, 0, 1);
			break;
		case 2:
			base64_encode(&b, s[0], s[1], 0, 2);
			break;
	}

	luaL_pushresult(&b);
	return 1;
}

static void base64_decode(luaL_Buffer* b, int c1, int c2, int c3, int c4, int n) {
	unsigned long tuple = c4 + 64L * (c3 + 64L * (c2 + 64L * c1));
	char s[3];

	switch(--n) {
		case 3:
			s[2] = (char) tuple;
		case 2:
			s[1] = (char)(tuple >> 8);
		case 1:
			s[0] = (char)(tuple >> 16);
	}

	luaL_addlstring(b, s, n);
}

static int Lbase64_decode(lua_State* L) {	/** decode(s) */
	size_t l;
	const char* s = luaL_checklstring(L, 1, &l);
	luaL_Buffer b;
	int n = 0;
	char t[4];
	luaL_buffinit(L, &b);

	for(;;) {
		int c = *s++;

		switch(c) {
				const char* p;
			default:
				p = strchr(code, c);

				if(p == NULL) {
					return 0;
				}

				t[n++] = (char)(p - code);

				if(n == 4) {
					base64_decode(&b, t[0], t[1], t[2], t[3], 4);
					n = 0;
				}

				break;
			case '=':

				switch(n) {
					case 1:
						base64_decode(&b, t[0], 0, 0, 0, 1);
						break;
					case 2:
						base64_decode(&b, t[0], t[1], 0, 0, 2);
						break;
					case 3:
						base64_decode(&b, t[0], t[1], t[2], 0, 3);
						break;
				}

				n = 0;
				break;
			case 0:
				luaL_pushresult(&b);
				return 1;
			case '\n':
			case '\r':
			case '\t':
			case ' ':
			case '\f':
			case '\b':
				break;
		}
	}
}

static const luaL_Reg Reg_base64[] = {
	{ "encode",	Lbase64_encode	},
	{ "decode",	Lbase64_decode	},
	{ NULL,		NULL	}
};

/******************* UTF-8 ********************/

/*
 * Adapted from Lua 5.3
 * Needed because libidn does not validate that input is valid UTF-8
 */

#define MAXUNICODE	0x10FFFF

/*
 * Decode one UTF-8 sequence, returning NULL if byte sequence is invalid.
 */
static const char* utf8_decode(const char* o, int* val) {
	static unsigned int limits[] = {0xFF, 0x7F, 0x7FF, 0xFFFF};
	const unsigned char* s = (const unsigned char*)o;
	unsigned int c = s[0];
	unsigned int res = 0;  /* final result */

	if(c < 0x80) { /* ascii? */
		res = c;
	} else {
		int count = 0;  /* to count number of continuation bytes */

		while(c & 0x40) {   /* still have continuation bytes? */
			int cc = s[++count];  /* read next byte */

			if((cc & 0xC0) != 0x80) { /* not a continuation byte? */
				return NULL;    /* invalid byte sequence */
			}

			res = (res << 6) | (cc & 0x3F);  /* add lower 6 bits from cont. byte */
			c <<= 1;  /* to test next bit */
		}

		res |= ((c & 0x7F) << (count * 5));  /* add first byte */

		if(count > 3 || res > MAXUNICODE || res <= limits[count] || (0xd800 <= res && res <= 0xdfff)) {
			return NULL;    /* invalid byte sequence */
		}

		s += count;  /* skip continuation bytes read */
	}

	if(val) {
		*val = res;
	}

	return (const char*)s + 1;   /* +1 to include first byte */
}

/*
 * Check that a string is valid UTF-8
 * Returns NULL if not
 */
const char* check_utf8(lua_State* L, int idx, size_t* l) {
	size_t pos, len;
	const char* s = luaL_checklstring(L, 1, &len);
	pos = 0;

	while(pos <= len) {
		const char* s1 = utf8_decode(s + pos, NULL);

		if(s1 == NULL) {   /* conversion error? */
			return NULL;
		}

		pos = s1 - s;
	}

	if(l != NULL) {
		*l = len;
	}

	return s;
}

static int Lutf8_valid(lua_State* L) {
	lua_pushboolean(L, check_utf8(L, 1, NULL) != NULL);
	return 1;
}

static int Lutf8_length(lua_State* L) {
	size_t len;

	if(!check_utf8(L, 1, &len)) {
		lua_pushnil(L);
		lua_pushliteral(L, "invalid utf8");
		return 2;
	}

	lua_pushinteger(L, len);
	return 1;
}

static const luaL_Reg Reg_utf8[] = {
	{ "valid",	Lutf8_valid	},
	{ "length",	Lutf8_length	},
	{ NULL,		NULL	}
};


/***************** STRINGPREP *****************/
#ifdef USE_STRINGPREP_ICU

#include <unicode/usprep.h>
#include <unicode/ustring.h>
#include <unicode/utrace.h>

static int icu_stringprep_prep(lua_State* L, const UStringPrepProfile* profile) {
	size_t input_len;
	int32_t unprepped_len, prepped_len, output_len;
	const char* input;
	char output[1024];

	UChar unprepped[1024]; /* Temporary unicode buffer (1024 characters) */
	UChar prepped[1024];

	UErrorCode err = U_ZERO_ERROR;

	if(!lua_isstring(L, 1)) {
		lua_pushnil(L);
		return 1;
	}

	input = lua_tolstring(L, 1, &input_len);

	if(input_len >= 1024) {
		lua_pushnil(L);
		return 1;
	}

	u_strFromUTF8(unprepped, 1024, &unprepped_len, input, input_len, &err);

	if(U_FAILURE(err)) {
		lua_pushnil(L);
		return 1;
	}

	prepped_len = usprep_prepare(profile, unprepped, unprepped_len, prepped, 1024, 0, NULL, &err);

	if(U_FAILURE(err)) {
		lua_pushnil(L);
		return 1;
	} else {
		u_strToUTF8(output, 1024, &output_len, prepped, prepped_len, &err);

		if(U_SUCCESS(err) && output_len < 1024) {
			lua_pushlstring(L, output, output_len);
		} else {
			lua_pushnil(L);
		}

		return 1;
	}
}

UStringPrepProfile* icu_nameprep;
UStringPrepProfile* icu_nodeprep;
UStringPrepProfile* icu_resourceprep;
UStringPrepProfile* icu_saslprep;

/* initialize global ICU stringprep profiles */
void init_icu() {
	UErrorCode err = U_ZERO_ERROR;
	utrace_setLevel(UTRACE_VERBOSE);
	icu_nameprep = usprep_openByType(USPREP_RFC3491_NAMEPREP, &err);
	icu_nodeprep = usprep_openByType(USPREP_RFC3920_NODEPREP, &err);
	icu_resourceprep = usprep_openByType(USPREP_RFC3920_RESOURCEPREP, &err);
	icu_saslprep = usprep_openByType(USPREP_RFC4013_SASLPREP, &err);

	if(U_FAILURE(err)) {
		fprintf(stderr, "[c] util.encodings: error: %s\n", u_errorName((UErrorCode)err));
	}
}

#define MAKE_PREP_FUNC(myFunc, prep) \
static int myFunc(lua_State *L) { return icu_stringprep_prep(L, prep); }

MAKE_PREP_FUNC(Lstringprep_nameprep, icu_nameprep)		/** stringprep.nameprep(s) */
MAKE_PREP_FUNC(Lstringprep_nodeprep, icu_nodeprep)		/** stringprep.nodeprep(s) */
MAKE_PREP_FUNC(Lstringprep_resourceprep, icu_resourceprep)		/** stringprep.resourceprep(s) */
MAKE_PREP_FUNC(Lstringprep_saslprep, icu_saslprep)		/** stringprep.saslprep(s) */

static const luaL_Reg Reg_stringprep[] = {
	{ "nameprep",	Lstringprep_nameprep	},
	{ "nodeprep",	Lstringprep_nodeprep	},
	{ "resourceprep",	Lstringprep_resourceprep	},
	{ "saslprep",	Lstringprep_saslprep	},
	{ NULL,		NULL	}
};
#else /* USE_STRINGPREP_ICU */

/****************** libidn ********************/

#include <stringprep.h>

static int stringprep_prep(lua_State* L, const Stringprep_profile* profile) {
	size_t len;
	const char* s;
	char string[1024];
	int ret;

	if(!lua_isstring(L, 1)) {
		lua_pushnil(L);
		return 1;
	}

	s = check_utf8(L, 1, &len);

	if(s == NULL || len >= 1024 || len != strlen(s)) {
		lua_pushnil(L);
		return 1; /* TODO return error message */
	}

	strcpy(string, s);
	ret = stringprep(string, 1024, (Stringprep_profile_flags)0, profile);

	if(ret == STRINGPREP_OK) {
		lua_pushstring(L, string);
		return 1;
	} else {
		lua_pushnil(L);
		return 1; /* TODO return error message */
	}
}

#define MAKE_PREP_FUNC(myFunc, prep) \
static int myFunc(lua_State *L) { return stringprep_prep(L, prep); }

MAKE_PREP_FUNC(Lstringprep_nameprep, stringprep_nameprep)		/** stringprep.nameprep(s) */
MAKE_PREP_FUNC(Lstringprep_nodeprep, stringprep_xmpp_nodeprep)		/** stringprep.nodeprep(s) */
MAKE_PREP_FUNC(Lstringprep_resourceprep, stringprep_xmpp_resourceprep)		/** stringprep.resourceprep(s) */
MAKE_PREP_FUNC(Lstringprep_saslprep, stringprep_saslprep)		/** stringprep.saslprep(s) */

static const luaL_Reg Reg_stringprep[] = {
	{ "nameprep",	Lstringprep_nameprep	},
	{ "nodeprep",	Lstringprep_nodeprep	},
	{ "resourceprep",	Lstringprep_resourceprep	},
	{ "saslprep",	Lstringprep_saslprep	},
	{ NULL,		NULL	}
};
#endif

/***************** IDNA *****************/
#ifdef USE_STRINGPREP_ICU
#include <unicode/ustdio.h>
#include <unicode/uidna.h>
/* IDNA2003 or IDNA2008 ? ? ? */
static int Lidna_to_ascii(lua_State* L) {	/** idna.to_ascii(s) */
	size_t len;
	int32_t ulen, dest_len, output_len;
	const char* s = luaL_checklstring(L, 1, &len);
	UChar ustr[1024];
	UErrorCode err = U_ZERO_ERROR;
	UChar dest[1024];
	char output[1024];

	u_strFromUTF8(ustr, 1024, &ulen, s, len, &err);

	if(U_FAILURE(err)) {
		lua_pushnil(L);
		return 1;
	}

	dest_len = uidna_IDNToASCII(ustr, ulen, dest, 1024, UIDNA_USE_STD3_RULES, NULL, &err);

	if(U_FAILURE(err)) {
		lua_pushnil(L);
		return 1;
	} else {
		u_strToUTF8(output, 1024, &output_len, dest, dest_len, &err);

		if(U_SUCCESS(err) && output_len < 1024) {
			lua_pushlstring(L, output, output_len);
		} else {
			lua_pushnil(L);
		}

		return 1;
	}
}

static int Lidna_to_unicode(lua_State* L) {	/** idna.to_unicode(s) */
	size_t len;
	int32_t ulen, dest_len, output_len;
	const char* s = luaL_checklstring(L, 1, &len);
	UChar ustr[1024];
	UErrorCode err = U_ZERO_ERROR;
	UChar dest[1024];
	char output[1024];

	u_strFromUTF8(ustr, 1024, &ulen, s, len, &err);

	if(U_FAILURE(err)) {
		lua_pushnil(L);
		return 1;
	}

	dest_len = uidna_IDNToUnicode(ustr, ulen, dest, 1024, UIDNA_USE_STD3_RULES, NULL, &err);

	if(U_FAILURE(err)) {
		lua_pushnil(L);
		return 1;
	} else {
		u_strToUTF8(output, 1024, &output_len, dest, dest_len, &err);

		if(U_SUCCESS(err) && output_len < 1024) {
			lua_pushlstring(L, output, output_len);
		} else {
			lua_pushnil(L);
		}

		return 1;
	}
}

#else /* USE_STRINGPREP_ICU */
/****************** libidn ********************/

#include <idna.h>
#include <idn-free.h>

static int Lidna_to_ascii(lua_State* L) {	/** idna.to_ascii(s) */
	size_t len;
	const char* s = check_utf8(L, 1, &len);
	char* output = NULL;
	int ret;

	if(s == NULL || len != strlen(s)) {
		lua_pushnil(L);
		return 1; /* TODO return error message */
	}

	ret = idna_to_ascii_8z(s, &output, IDNA_USE_STD3_ASCII_RULES);

	if(ret == IDNA_SUCCESS) {
		lua_pushstring(L, output);
		idn_free(output);
		return 1;
	} else {
		lua_pushnil(L);
		idn_free(output);
		return 1; /* TODO return error message */
	}
}

static int Lidna_to_unicode(lua_State* L) {	/** idna.to_unicode(s) */
	size_t len;
	const char* s = luaL_checklstring(L, 1, &len);
	char* output = NULL;
	int ret = idna_to_unicode_8z8z(s, &output, 0);

	if(ret == IDNA_SUCCESS) {
		lua_pushstring(L, output);
		idn_free(output);
		return 1;
	} else {
		lua_pushnil(L);
		idn_free(output);
		return 1; /* TODO return error message */
	}
}
#endif

static const luaL_Reg Reg_idna[] = {
	{ "to_ascii",	Lidna_to_ascii	},
	{ "to_unicode",	Lidna_to_unicode	},
	{ NULL,		NULL	}
};

/***************** end *****************/

LUALIB_API int luaopen_util_encodings(lua_State* L) {
#ifdef USE_STRINGPREP_ICU
	init_icu();
#endif
	lua_newtable(L);

	lua_newtable(L);
	luaL_setfuncs(L, Reg_base64, 0);
	lua_setfield(L, -2, "base64");

	lua_newtable(L);
	luaL_setfuncs(L, Reg_stringprep, 0);
	lua_setfield(L, -2, "stringprep");

	lua_newtable(L);
	luaL_setfuncs(L, Reg_idna, 0);
	lua_setfield(L, -2, "idna");

	lua_newtable(L);
	luaL_setfuncs(L, Reg_utf8, 0);
	lua_setfield(L, -2, "utf8");

	lua_pushliteral(L, "-3.14");
	lua_setfield(L, -2, "version");
	return 1;
}
