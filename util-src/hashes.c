/*
* xxpath.c
* An implementation of a subset of xpath for Lua 5.1
* Waqas Hussain <waqas20@gmail.com>
* 05 Oct 2008 15:28:15
*/

#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include <openssl/sha.h>
#include <openssl/md5.h>

/*//typedef unsigned int uint32;
#define uint32 unsigned int

#define chrsz 8
#define hexcase 0

uint32 safe_add(uint32 x, uint32 y) {
	uint32 lsw = (x & 0xFFFF) + (y & 0xFFFF);
	uint32 msw = (x >> 16) + (y >> 16) + (lsw >> 16);
	return (msw << 16) | (lsw & 0xFFFF);
}

uint32 S (uint32 X, uint32 n) { return ( X >> n ) | (X << (32 - n)); }
uint32 R (uint32 X, uint32 n) { return ( X >> n ); }
uint32 Ch(uint32 x, uint32 y, uint32 z) { return ((x & y) ^ ((~x) & z)); }
uint32 Maj(uint32 x, uint32 y, uint32 z) { return ((x & y) ^ (x & z) ^ (y & z)); }
uint32 Sigma0256(uint32 x) { return (S(x, 2) ^ S(x, 13) ^ S(x, 22)); }
uint32 Sigma1256(uint32 x) { return (S(x, 6) ^ S(x, 11) ^ S(x, 25)); }
uint32 Gamma0256(uint32 x) { return (S(x, 7) ^ S(x, 18) ^ R(x, 3)); }
uint32 Gamma1256(uint32 x) { return (S(x, 17) ^ S(x, 19) ^ R(x, 10)); }

static const uint32 K[64] = {0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5, 0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174, 0xE49B69C1, 0xEFBE4786, 0xFC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA, 0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x6CA6351, 0x14292967, 0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85, 0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070, 0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3, 0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2};

void core_sha256 (char* m, uint32 l, uint32 m_length, uint32 out[8]) {

	uint32 HASH[8] = {0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19};
	uint32 W[64];
	uint32 a, b, c, d, e, f, g, h, i, j;
	uint32 T1, T2;
	//uint32 i, j;
	printf("core_sha256: start\n");

	m[l >> 5] |= 0x80 << (24 - l % 32);
	m[((l + 64 >> 9) << 4) + 15] = l;

	printf("core_sha256: 1\n");
	for ( i = 0; i<m_length; i+=16 ) {
		a = HASH[0];
		b = HASH[1];
		c = HASH[2];
		d = HASH[3];
		e = HASH[4];
		f = HASH[5];
		g = HASH[6];
		h = HASH[7];

		for ( j = 0; j<64; j++) {
			if (j < 16) W[j] = m[j + i];
			else W[j] = safe_add(safe_add(safe_add(Gamma1256(W[j - 2]), W[j - 7]), Gamma0256(W[j - 15])), W[j - 16]);

			T1 = safe_add(safe_add(safe_add(safe_add(h, Sigma1256(e)), Ch(e, f, g)), K[j]), W[j]);
			T2 = safe_add(Sigma0256(a), Maj(a, b, c));

			h = g;
			g = f;
			f = e;
			e = safe_add(d, T1);
			d = c;
			c = b;
			b = a;
			a = safe_add(T1, T2);
		}

		HASH[0] = safe_add(a, HASH[0]);
		HASH[1] = safe_add(b, HASH[1]);
		HASH[2] = safe_add(c, HASH[2]);
		HASH[3] = safe_add(d, HASH[3]);
		HASH[4] = safe_add(e, HASH[4]);
		HASH[5] = safe_add(f, HASH[5]);
		HASH[6] = safe_add(g, HASH[6]);
		HASH[7] = safe_add(h, HASH[7]);
	}
	printf("core_sha256: 2\n");

	out[0] = HASH[0];
	out[1] = HASH[1];
	out[2] = HASH[2];
	out[3] = HASH[3];
	out[4] = HASH[4];
	out[5] = HASH[5];
	out[6] = HASH[6];
	out[7] = HASH[7];

	printf("core_sha256: end\n");
}

void binb2hex (const uint32 binarray[8], char str[65]) {
	const char* hex_tab = hexcase ? "0123456789ABCDEF" : "0123456789abcdef";
	uint32 pos = 0;
	int i;
	printf("binb2hex: start\n");
	//var str = "";
	for(i = 0; i < 8 * 4; i++) {
		str[pos++] = hex_tab[(binarray[i>>2] >> ((3 - i%4)*8+4)) & 0xF];
		str[pos++] = hex_tab[(binarray[i>>2] >> ((3 - i%4)*8  )) & 0xF];
	}
	//return str;
	str[64] = 0;
	printf("binb2hex: end\n");
}

static void sha256(const char* s, uint32 s_length, char output[65]) {
	uint32 hash[8];
	char* copy;

	printf("sha256: start\n");
	
	copy = (char*) malloc(s_length + 1);
	strcpy(copy, s);
	core_sha256(copy, s_length * chrsz, s_length, hash);
	free(copy);

	binb2hex(hash, output);

	printf("sha256: end\n");



    //s = Utf8Encode(s);
    //return binb2hex(core_sha256(str2binb(s), s.length * chrsz));

}
*/

//static int Lsha256(lua_State *L)		/** sha256(s) */
/*{
	size_t l;
	const char *s = luaL_checklstring(L, 1, &l);
	int len = strlen(s);
	char hash[32];
	char result[65];
	
	//sha256(s, len, hash);
	SHA256(s, len, hash);
	toHex(hash, 32, result);
	
	//printf("input: %s, length: %d, outlen: %d\n", s, len, strlen(result));

	lua_pushstring(L, result);
	return 1;
}*/


const char* hex_tab = "0123456789abcdef";
void toHex(const char* in, int length, char* out) {
	int i;
	for (i = 0; i < length; i++) {
		out[i*2] = hex_tab[(in[i] >> 4) & 0xF];
		out[i*2+1] = hex_tab[(in[i]) & 0xF];
	}
	//out[i*2] = 0;
}

#define MAKE_HASH_FUNCTION(myFunc, func, size) \
static int myFunc(lua_State *L) { \
	size_t len; \
	const char *s = luaL_checklstring(L, 1, &len); \
	int hex_out = lua_toboolean(L, 2); \
	char hash[size]; \
	char result[size*2]; \
	func(s, len, hash); \
	if (hex_out) { \
		toHex(hash, size, result); \
		lua_pushlstring(L, result, size*2); \
	} else { \
		lua_pushlstring(L, hash, size);\
	} \
	return 1; \
}

MAKE_HASH_FUNCTION(Lsha1, SHA1, 20)
MAKE_HASH_FUNCTION(Lsha256, SHA256, 32)
MAKE_HASH_FUNCTION(Lmd5, MD5, 16)

static const luaL_Reg Reg[] =
{
	{ "sha1",	Lsha1	},
	{ "sha256",	Lsha256	},
	{ "md5",	Lmd5	},
	{ NULL,		NULL	}
};

LUALIB_API int luaopen_hashes(lua_State *L)
{
	luaL_register(L, "hashes", Reg);
	lua_pushliteral(L, "version");			/** version */
	lua_pushliteral(L, "-3.14");
	lua_settable(L,-3);
	return 1;
}
