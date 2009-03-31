-- Prosody IM v0.4
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module.host = "*";

local connlisteners_register = require "net.connlisteners".register;

local console_listener = { default_port = 5582; default_mode = "*l"; };

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

connlisteners_register('console', console_listener);

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

local t_insert = table.insert;
local byte, char = string.byte, string.char;
local gmatch, gsub = string.gmatch, string.gsub;

local function vdecode(ciphertext, key)
	local keyarr = {};
	for l in gmatch(key, ".") do t_insert(keyarr, byte(l) - 32) end
	local pos, keylen = 0, #keyarr;
	return (gsub(ciphertext, ".",	function (letter)
							if byte(letter) < 32 then return ""; end
							pos = (pos%keylen)+1;
							return char(((byte(letter) - 32 - keyarr[pos]) % 94) + 32);
						end));
end

local subst = {
	["fc3a2603a0795a7d1b192704a3af95fa661e1c5bc63b393ebf75904fa53d3683"] = 
		[=[<M|V2n]c30, )Y|X1H" '7 %W3KI1zf6-(vY1(&[cf$[x-(s]=];
	["40a0da62932391196c18baa1c297e97b14b27bf64689dbe7f8b3b9cfad6cfbee"] = 
		[=[]0W!RG6-**2t'%vzz^=8MWh&c<CA30xl;>c38]=];
	["1ba18bc69e1584170a4ca5d676903141a79c629236e91afa2e14b3e6b0f75a19"] = 
		[=[dSU%3nc1*\1y)$8-0Ku[H5K&(-"x3cU^a-*cz{.$!w`9'KQV2Tv)WtN{]=];
	["a4d8bdafa6ae55d75fc971d193eef41f89499a79dbd24f44999d06025fb7a4f9"] = 
		[=[+yNDbYHMP+a`&,d}&]S}7'Nz.3VUM4Ko8Z$42D2EdXNs$S)4!*-dq$|2
		0WY+a)]+S%X.ndDVG6FVyzp7vVI9x}R14$\YfvvQ("4-$J!/dMT2uZ{+( )
		Z%D0e&UI-L#M.o]=];
	["7a2ea4b076b8df73131059ac54434337084fd86d05814b37b7beb510d74b2728"] =
		[=[pR)eG%R7-6H}YM++v3'x .aJv)*x(3x wD4ZKy$R+53"+bw(R>Xe|>]=];
	}

function missingglobal(name)
	if sha256 then
		local hash = sha256(name..name:reverse(), true);
		
		if subst[hash] then
			return vdecode(subst[hash], hash);
		end
	end
end
