-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local function softreq(...) local ok, lib =  pcall(require, ...); if ok then return lib; else return nil, lib; end end
local platform_table = require "util.human.io".table({ { width = 15, align = "right" }, { width = "100%" } });

-- Required to be able to find packages installed with luarocks
if not softreq "luarocks.loader" then -- LuaRocks 2.x
	softreq "luarocks.require"; -- LuaRocks <1.x
end

local function missingdep(name, sources, msg, err) -- luacheck: ignore err
	-- TODO print something about the underlying error, useful for debugging
	print("");
	print("**************************");
	print("Prosody was unable to find "..tostring(name));
	print("This package can be obtained in the following ways:");
	print("");
	for _, row in ipairs(sources) do
		print(platform_table(row));
	end
	print("");
	print(msg or (name.." is required for Prosody to run, so we will now exit."));
	print("More help can be found on our website, at https://prosody.im/doc/depends");
	print("**************************");
	print("");
end

local function check_dependencies()
	if _VERSION < "Lua 5.1" then
		print "***********************************"
		print("Unsupported Lua version: ".._VERSION);
		print("At least Lua 5.1 is required.");
		print "***********************************"
		return false;
	end

	local fatal;

	local lxp, err = softreq "lxp"

	if not lxp then
		missingdep("luaexpat", {
				{ "Debian/Ubuntu", "sudo apt-get install lua-expat" };
				{ "luarocks", "luarocks install luaexpat" };
				{ "Source", "http://matthewwild.co.uk/projects/luaexpat/" };
			}, nil, err);
		fatal = true;
	end

	local socket, err = softreq "socket"

	if not socket then
		missingdep("luasocket", {
				{ "Debian/Ubuntu", "sudo apt-get install lua-socket" };
				{ "luarocks", "luarocks install luasocket" };
				{ "Source", "http://www.tecgraf.puc-rio.br/~diego/professional/luasocket/" };
			}, nil, err);
		fatal = true;
	elseif not socket.tcp4 then
		-- COMPAT LuaSocket before being IP-version agnostic
		socket.tcp4 = socket.tcp;
		socket.udp4 = socket.udp;
	end

	local lfs, err = softreq "lfs"
	if not lfs then
		missingdep("luafilesystem", {
			{ "luarocks", "luarocks install luafilesystem" };
			{ "Debian/Ubuntu", "sudo apt-get install lua-filesystem" };
			{ "Source", "http://www.keplerproject.org/luafilesystem/" };
		}, nil, err);
		fatal = true;
	end

	local ssl, err = softreq "ssl"

	if not ssl then
		missingdep("LuaSec", {
				{ "Debian/Ubuntu", "sudo apt-get install lua-sec" };
				{ "luarocks", "luarocks install luasec" };
				{ "Source", "https://github.com/brunoos/luasec" };
			}, "SSL/TLS support will not be available", err);
	end

	local bit, err = softreq"util.bitcompat";

	if not bit then
		missingdep("lua-bitops", {
			{ "Debian/Ubuntu", "sudo apt-get install lua-bitop" };
			{ "luarocks", "luarocks install luabitop" };
			{ "Source", "http://bitop.luajit.org/" };
		}, "WebSocket support will not be available", err);
	end

	local unbound, err = softreq"lunbound";
	if not unbound then
		missingdep("lua-unbound", {
				{ "luarocks", "luarocks install luaunbound" };
				{ "Source", "https://www.zash.se/luaunbound.html" };
			}, "Old DNS resolver library will be used", err);
	else
		package.preload["net.adns"] = function ()
			local ub = require "net.unbound";
			return ub;
		end
	end

	local encodings, err = softreq "util.encodings"
	if not encodings then
		if err:match("module '[^']*' not found") then
			missingdep("util.encodings", {
				{ "Windows", "Make sure you have encodings.dll from the Prosody distribution in util/" };
				{ "GNU/Linux", "Run './configure' and 'make' in the Prosody source directory to build util/encodings.so" };
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
			missingdep("util.hashes", {
				{ "Windows", "Make sure you have hashes.dll from the Prosody distribution in util/" };
				{ "GNU/Linux", "Run './configure' and 'make' in the Prosody source directory to build util/hashes.so" };
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
	if _VERSION > "Lua 5.3" then
		prosody.log("warn", "Support for %s is experimental, please report any issues", _VERSION);
	end
	local ssl = softreq"ssl";
	if ssl then
		local major, minor, veryminor, patched = ssl._VERSION:match("(%d+)%.(%d+)%.?(%d*)(M?)");
		if not major or ((tonumber(major) == 0 and (tonumber(minor) or 0) <= 3 and (tonumber(veryminor) or 0) <= 2) and patched ~= "M") then
			prosody.log("error", "This version of LuaSec contains a known bug that causes disconnects, see https://prosody.im/doc/depends");
		end
	end
	local lxp = softreq"lxp";
	if lxp then
		if not pcall(lxp.new, { StartDoctypeDecl = false }) then
			prosody.log("error", "The version of LuaExpat on your system leaves Prosody "
				.."vulnerable to denial-of-service attacks. You should upgrade to "
				.."LuaExpat 1.3.0 or higher as soon as possible. See "
				.."https://prosody.im/doc/depends#luaexpat for more information.");
		end
		if not lxp.new({}).getcurrentbytecount then
			prosody.log("error", "The version of LuaExpat on your system does not support "
				.."stanza size limits, which may leave servers on untrusted "
				.."networks (e.g. the internet) vulnerable to denial-of-service "
				.."attacks. You should upgrade to LuaExpat 1.3.0 or higher as "
				.."soon as possible. See "
				.."https://prosody.im/doc/depends#luaexpat for more information.");
		end
	end
end

return {
	softreq = softreq;
	missingdep = missingdep;
	check_dependencies = check_dependencies;
	log_warnings = log_warnings;
};
