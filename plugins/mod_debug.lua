-- Prosody IM
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module.host = "*";

local connlisteners_register = require "net.connlisteners".register;

local console_listener = { default_port = 5583; default_mode = "*l"; default_interface = "127.0.0.1" };

local sha256, missingglobal = require "util.hashes".sha256;

local commands = {};
local debug_env = {};
local debug_env_mt = { __index = function (t, k) return rawget(_G, k) or missingglobal(k); end, __newindex = function (t, k, v) rawset(_G, k, v); end };

local t_insert, t_concat = table.insert, table.concat;
local t_concatall = function (t, sep) local tt = {}; for k, s in pairs(t) do tt[k] = tostring(s); end return t_concat(tt, sep); end


setmetatable(debug_env, debug_env_mt);

console = {};

function console:new_session(conn)
	local w = function(s) conn.write(s:gsub("\n", "\r\n")); end;
	local session = { conn = conn;
			send = function (t) w(tostring(t)); end;
			print = function (t) w("| "..tostring(t).."\n"); end;
			disconnect = function () conn.close(); end;
			};
	
	return session;
end

local sessions = {};

function console_listener.listener(conn, data)
	local session = sessions[conn];
	
	if not session then
		-- Handle new connection
		session = console:new_session(conn);
		sessions[conn] = session;
		printbanner(session);
	end
	if data then
		-- Handle data
		(function(session, data)
			if data:match("[!.]$") then
				local command = data:lower();
				command = data:match("^%w+") or data:match("%p");
				if commands[command] then
					commands[command](session, data);
					return;
				end
			end
			
			local chunk, err = loadstring("return "..data);
			if not chunk then
				chunk, err = loadstring(data);
				if not chunk then
					err = err:gsub("^%[string .-%]:%d+: ", "");
					err = err:gsub("^:%d+: ", "");
					err = err:gsub("'<eof>'", "the end of the line");
					session.print("Sorry, I couldn't understand that... "..err);
					return;
				end
			end
			
			debug_env.print = session.print;
			
			setfenv(chunk, debug_env);
			
			local ret = { pcall(chunk) };
			
			if not ret[1] then
				session.print("Fatal error while running command, it did not complete");
				session.print("Error: "..ret[2]);
				return;
			end
			
			table.remove(ret, 1);
			
			local retstr = t_concatall(ret, ", ");
			if retstr ~= "" then
				session.print("Result: "..retstr);
			else
				session.print("No result, or nil");
				return;
			end
		end)(session, data);
	end
	session.send(string.char(0));
end

function console_listener.disconnect(conn, err)
	
end

connlisteners_register('debug', console_listener);
require "net.connlisteners".start("debug");

-- Console commands --
-- These are simple commands, not valid standalone in Lua

function commands.bye(session)
	session.print("See you! :)");
	session.disconnect();
end

commands["!"] = function (session, data)
	if data:match("^!!") then
		session.print("!> "..session.env._);
		return console_listener.listener(session.conn, session.env._);
	end
	local old, new = data:match("^!(.-[^\\])!(.-)!$");
	if old and new then
		local ok, res = pcall(string.gsub, session.env._, old, new);
		if not ok then
			session.print(res)
			return;
		end
		session.print("!> "..res);
		return console_listener.listener(session.conn, res);
	end
	session.print("Sorry, not sure what you want");
end

function printbanner(session)
session.print [[
                   ____                \   /     _       
                    |  _ \ _ __ ___  ___  _-_   __| |_   _ 
                    | |_) | '__/ _ \/ __|/ _ \ / _` | | | |
                    |  __/| | | (_) \__ \ |_| | (_| | |_| |
                    |_|   |_|  \___/|___/\___/ \__,_|\__, |
                    A study in simplicity            |___/ 

]]
session.print("Welcome to the Prosody debug console. For a list of commands, type: help");
session.print("You may find more help on using this console in our online documentation at ");
session.print("http://prosody.im/doc/debugconsole\n");
end

local byte, char = string.byte, string.char;
local gmatch, gsub = string.gmatch, string.gsub;

local function vdecode(text, key)
	local keyarr = {};
	for l in gmatch(key, ".") do t_insert(keyarr, byte(l) - 32) end
	local pos, keylen = 0, #keyarr;
	return (gsub(text, ".",	function (letter)
							if byte(letter) < 32 then return ""; end
							pos = (pos%keylen)+1;
							return char(((byte(letter) - 32 - keyarr[pos]) % 94) + 32);
						end));
end

local subst = {
	["f880c08056ba7dbecb1ccfe5d7728bd6dcd654e94f7a9b21788c43397bae0bc5"] =
		[=[nRYeKR$l'5Ix%u*1Mc-K}*bwv*\ $1KLMBd$KH R38`$[6}VQ@,6Qn]=];
	["92f718858322157202ec740698c1390e47bc819e52b6a099c54c378a9f7529d6"] =
		[=[V\Z5`WZ5,T$<)7LM'w3Z}M(7V'{pa) &'>0+{v)O(0M*V5K$$LL$|2wT}6
		 1as*")e!>]=];
	["467b65edcc7c7cd70abf2136cc56abd037216a6cd9e17291a2219645be2e2216"] =
		[=[i#'Z,E1-"YaHW(j/0xs]I4x&%(Jx1h&18'(exNWT D3b+K{*8}w(%D {]=];
	["f73729d7f2fbe686243a25ac088c7e6aead3d535e081329f2817438a5c78bee5"] =
		[=[,3+(Q{3+W\ftQ%wvv/C0z-l%f>ABc(vkp<bb8]=];
	["6afa189489b096742890d0c5bd17d5bb8af8ac460c7026984b64e8f14a40404e"] =
		[=[9N{)5j34gd*}&]H&dy"I&7(",a F1v6jY+IY7&S+86)1z(Vo]=];
	["cc5e5293ef8a1acbd9dd2bcda092c5c77ef46d3ec5aea65024fca7ed4b3c94a9"] = 
		[=[_]Rc}IF'Kfa&))Ry+6|x!K2|T*Vze)%4Hwz'L3uI|OwIa)|q#uq2+Qu u7
		[V3(z(*TYY|T\1_W'2] Dwr{-{@df#W.H5^x(ydtr{c){UuV@]=];
	["b3df231fd7ddf73f72f39cb2510b1fe39318f4724728ed58948a180663184d3e"] =
		[=[iH!"9NLS'%geYw3^R*fvWM1)MwxLS!d[zP(p0sQ|8tX{dWO{9w!+W)b"MU
		W)V8&(2Wx"'dTL9*PP%1"JV(I|Jr1^f'-Hc3U\2H3Z='K#,)dPm]=];
	}

function missingglobal(name)
	if sha256 then
		local hash = sha256(name.."|"..name:reverse(), true);
		
		if subst[hash] then
			return vdecode(subst[hash], sha256(name:reverse(), true));
		end
	end
end
