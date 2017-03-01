-- Prosody IM
-- Copyright (C) 2008-2011 Florian Zeitz
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- luacheck: ignore 113/setfenv

local load, loadstring, setfenv = load, loadstring, setfenv;
local io_open = io.open;
local envload;
local envloadfile;

if setfenv then
	function envload(code, source, env)
		local f, err = loadstring(code, source);
		if f and env then setfenv(f, env); end
		return f, err;
	end

	function envloadfile(file, env)
		local fh, err, errno = io_open(file);
		if not fh then return fh, err, errno; end
		local f, err = load(function () return fh:read(2048); end, "@"..file);
		if f and env then setfenv(f, env); end
		return f, err;
	end
else
	function envload(code, source, env)
		return load(code, source, nil, env);
	end

	function envloadfile(file, env)
		local fh, err, errno = io_open(file);
		if not fh then return fh, err, errno; end
		return load(fh:lines(2048), "@"..file, nil, env);
	end
end

return { envload = envload, envloadfile = envloadfile };
