-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local function softreq(...) local ok, lib =  pcall(require, ...); if ok then return lib; else return nil, lib; end end

-- Required to be able to find packages installed with luarocks
if not softreq "luarocks.loader" then -- LuaRocks 2.x
	softreq "luarocks.require"; -- LuaRocks <1.x
end

local function missingdep(name, sources, msg)
	print("");
	print("**************************");
	print("Prosody was unable to find "..tostring(name));
	print("This package can be obtained in the following ways:");
	print("");
	local longest_platform = 0;
	for platform in pairs(sources) do
		longest_platform = math.max(longest_platform, #platform);
	end
	for platform, source in pairs(sources) do
		print("", platform..":"..(" "):rep(4+longest_platform-#platform)..source);
	end
	print("");
	print(msg or (name.." is required for Prosody to run, so we will now exit."));
	print("More help can be found on our website, at http://prosody.im/doc/depends");
	print("**************************");
	print("");
end

-- COMPAT w/pre-0.8 Debian: The Debian config file used to use
-- util.ztact, which has been removed from Prosody in 0.8. This
-- is to log an error for people who still use it, so they can
-- update their configs.
package.preload["util.ztact"] = function ()
	if not package.loaded["core.loggingmanager"] then
		error("util.ztact has been removed from Prosody and you need to fix your config "
		    .."file. More information can be found at http://prosody.im/doc/packagers#ztact", 0);
	else
		error("module 'util.ztact' has been deprecated in Prosody 0.8.");
	end
end;

local function check_dependencies()
	if _VERSION < "Lua 5.1" then
		print "***********************************"
		print("Unsupported Lua version: ".._VERSION);
		print("At least Lua 5.1 is required.");
		print "***********************************"
		return false;
	end

	local fatal;

	local lxp = softreq "lxp"

	if not lxp then
		missingdep("luaexpat", {
				["Debian/Ubuntu"] = "sudo apt-get install liblua5.1-expat0";
				["luarocks"] = "luarocks install luaexpat";
				["Source"] = "http://www.keplerproject.org/luaexpat/";
			});
		fatal = true;
	end

	local socket = softreq "socket"

	if not socket then
		missingdep("luasocket", {
				["Debian/Ubuntu"] = "sudo apt-get install liblua5.1-socket2";
				["luarocks"] = "luarocks install luasocket";
				["Source"] = "http://www.tecgraf.puc-rio.br/~diego/professional/luasocket/";
			});
		fatal = true;
	end

	local lfs, err = softreq "lfs"
	if not lfs then
		missingdep("luafilesystem", {
				["luarocks"] = "luarocks install luafilesystem";
		 		["Debian/Ubuntu"] = "sudo apt-get install liblua5.1-filesystem0";
		 		["Source"] = "http://www.keplerproject.org/luafilesystem/";
		 	});
		fatal = true;
	end

	local ssl = softreq "ssl"

	if not ssl then
		missingdep("LuaSec", {
				["Debian/Ubuntu"] = "http://prosody.im/download/start#debian_and_ubuntu";
				["luarocks"] = "luarocks install luasec";
				["Source"] = "http://www.inf.puc-rio.br/~brunoos/luasec/";
			}, "SSL/TLS support will not be available");
	end

	local encodings, err = softreq "util.encodings"
	if not encodings then
		if err:match("module '[^']*' not found") then
			missingdep("util.encodings", { ["Windows"] = "Make sure you have encodings.dll from the Prosody distribution in util/";
		 				["GNU/Linux"] = "Run './configure' and 'make' in the Prosody source directory to build util/encodings.so";
		 			});
		else
			print "***********************************"
			print("util/encodings couldn't be loaded. Check that you have a recent version of libidn");
			print ""
			print("The full error was:");
			print(err)
			print "***********************************"
		end
		fatal = true;
	end

	local hashes, err = softreq "util.hashes"
	if not hashes then
		if err:match("module '[^']*' not found") then
			missingdep("util.hashes", { ["Windows"] = "Make sure you have hashes.dll from the Prosody distribution in util/";
		 				["GNU/Linux"] = "Run './configure' and 'make' in the Prosody source directory to build util/hashes.so";
		 			});
	 	else
			print "***********************************"
			print("util/hashes couldn't be loaded. Check that you have a recent version of OpenSSL (libcrypto in particular)");
			print ""
			print("The full error was:");
			print(err)
			print "***********************************"
		end
		fatal = true;
	end
	return not fatal;
end

local function log_warnings()
	if _VERSION > "Lua 5.1" then
		prosody.log("warn", "Support for %s is experimental, please report any issues", _VERSION);
	end
	local ssl = softreq"ssl";
	if ssl then
		local major, minor, veryminor, patched = ssl._VERSION:match("(%d+)%.(%d+)%.?(%d*)(M?)");
		if not major or ((tonumber(major) == 0 and (tonumber(minor) or 0) <= 3 and (tonumber(veryminor) or 0) <= 2) and patched ~= "M") then
			prosody.log("error", "This version of LuaSec contains a known bug that causes disconnects, see http://prosody.im/doc/depends");
		end
	end
	local lxp = softreq"lxp";
	if lxp then
		if not pcall(lxp.new, { StartDoctypeDecl = false }) then
			prosody.log("error", "The version of LuaExpat on your system leaves Prosody "
				.."vulnerable to denial-of-service attacks. You should upgrade to "
				.."LuaExpat 1.3.0 or higher as soon as possible. See "
				.."http://prosody.im/doc/depends#luaexpat for more information.");
		end
		if not lxp.new({}).getcurrentbytecount then
			prosody.log("error", "The version of LuaExpat on your system does not support "
				.."stanza size limits, which may leave servers on untrusted "
				.."networks (e.g. the internet) vulnerable to denial-of-service "
				.."attacks. You should upgrade to LuaExpat 1.3.0 or higher as "
				.."soon as possible. See "
				.."http://prosody.im/doc/depends#luaexpat for more information.");
		end
	end
end

return {
	softreq = softreq;
	missingdep = missingdep;
	check_dependencies = check_dependencies;
	log_warnings = log_warnings;
};
