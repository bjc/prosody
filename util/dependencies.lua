-- Prosody IM v0.3
-- Copyright (C) 2008-2009 Matthew Wild
-- Copyright (C) 2008-2009 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local fatal;

local function softreq(...) local ok, lib =  pcall(require, ...); if ok then return lib; else return nil; end end

local function missingdep(name, sources, msg)
	print("");
	print("**************************");
	print("Prosody was unable to find "..tostring(name));
	print("This package can be obtained in the following ways:");
	print("");
	for k,v in pairs(sources) do
		print("", k, v);
	end
	print("");
	print(msg or (name.." is required for Prosody to run, so we will now exit."));
	print("More help can be found on our website, at http://prosody.im/doc/depends");
	print("**************************");
	print("");
end

local lxp = softreq "lxp"

if not lxp then
	missingdep("luaexpat", { ["Ubuntu 8.04 (Hardy)"] = "sudo apt-get install liblua5.1-expat0"; ["luarocks"] = "luarocks install luaexpat"; });
	fatal = true;
end

local socket = softreq "socket"

if not socket then
	missingdep("luasocket", { ["Ubuntu 8.04 (Hardy)"] = "sudo apt-get install liblua5.1-socket2"; ["luarocks"] = "luarocks install luasocket"; });
	fatal = true;
end
	
local ssl = softreq "ssl"

if not ssl then
	if config.get("*", "core", "run_without_ssl") then
		log("warn", "Running without SSL support because run_without_ssl is defined in the config");
	else
		missingdep("LuaSec", { ["Source"] = "http://www.inf.puc-rio.br/~brunoos/luasec/" }, "SSL/TLS support will not be available");
	end
end

local encodings = softreq "util.encodings"
if not encodings then
	missingdep("util.encodings", { ["Windows"] = "Make sure you have encodings.dll from the Prosody distribution in util/";
	 				["GNU/Linux"] = "Run './configure' and 'make' in the Prosody source directory to build util/encodings.so";
	 			});
	fatal = true;
end

local encodings = softreq "util.hashes"
if not encodings then
	missingdep("util.hashes", { ["Windows"] = "Make sure you have hashes.dll from the Prosody distribution in util/";
	 				["GNU/Linux"] = "Run './configure' and 'make' in the Prosody source directory to build util/hashes.so";
	 			});
	fatal = true;
end

if fatal then os.exit(1); end
