/* Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
*/

/*
* windows.c
* Windows support functions for Lua
*/

#include <stdio.h>
#include <windows.h>
#include <windns.h>

#include "lua.h"
#include "lauxlib.h"

static int Lget_nameservers(lua_State *L) {
	char stack_buffer[1024]; // stack allocated buffer
	IP4_ARRAY* ips = (IP4_ARRAY*) stack_buffer;
	DWORD len = sizeof(stack_buffer);
	DNS_STATUS status;

	status = DnsQueryConfig(DnsConfigDnsServerList, FALSE, NULL, NULL, ips, &len);
	if (status == 0) {
		DWORD i;
		lua_createtable(L, ips->AddrCount, 0);
		for (i = 0; i < ips->AddrCount; i++) {
			DWORD ip = ips->AddrArray[i];
			char ip_str[16] = "";
			sprintf_s(ip_str, sizeof(ip_str), "%d.%d.%d.%d", (ip >> 0) & 255, (ip >> 8) & 255, (ip >> 16) & 255, (ip >> 24) & 255);
			lua_pushstring(L, ip_str);
			lua_rawseti(L, -2, i+1);
		}
		return 1;
	} else {
		lua_pushnil(L);
		lua_pushfstring(L, "DnsQueryConfig returned %d", status);
		return 2;
	}
}

static int lerror(lua_State *L, char* string) {
	lua_pushnil(L);
	lua_pushfstring(L, "%s: %d", string, GetLastError());
	return 2;
}

static int Lget_consolecolor(lua_State *L) {
	HWND console = GetStdHandle(STD_OUTPUT_HANDLE);
	WORD color; DWORD read_len;
	
	CONSOLE_SCREEN_BUFFER_INFO info;
	
	if (console == INVALID_HANDLE_VALUE) return lerror(L, "GetStdHandle");
	if (!GetConsoleScreenBufferInfo(console, &info)) return lerror(L, "GetConsoleScreenBufferInfo");
	if (!ReadConsoleOutputAttribute(console, &color, 1, info.dwCursorPosition, &read_len)) return lerror(L, "ReadConsoleOutputAttribute");

	lua_pushnumber(L, color);
	return 1;
}
static int Lset_consolecolor(lua_State *L) {
	int color = luaL_checkint(L, 1);
	HWND console = GetStdHandle(STD_OUTPUT_HANDLE);
	if (console == INVALID_HANDLE_VALUE) return lerror(L, "GetStdHandle");
	if (!SetConsoleTextAttribute(console, color)) return lerror(L, "SetConsoleTextAttribute");
	lua_pushboolean(L, 1);
	return 1;
}

static const luaL_Reg Reg[] =
{
	{ "get_nameservers",	Lget_nameservers	},
	{ "get_consolecolor",	Lget_consolecolor	},
	{ "set_consolecolor",	Lset_consolecolor	},
	{ NULL,		NULL	}
};

LUALIB_API int luaopen_util_windows(lua_State *L) {
	luaL_register(L, "windows", Reg);
	lua_pushliteral(L, "version");			/** version */
	lua_pushliteral(L, "-3.14");
	lua_settable(L,-3);
	return 1;
}
