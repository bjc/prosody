local fatal;

local function softreq(...) local ok, lib =  pcall(require, ...); if ok then return lib; else return nil; end end

local function missingdep(name, sources, msg)
	print("Prosody was unable to find "..tostring(name));
	print("This package can be obtained in the following ways:");
	print("");
	for k,v in pairs(sources) do
		print("", k, v);
	end
	print(msg or (name.." is required for Prosody to run, so we will now exit."));
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
	missingdep("LuaSec", { ["Source"] = "http://www.inf.puc-rio.br/~brunoos/luasec/" }, "SSL/TLS support will not be available");
end

if fatal then os.exit(1); end
