-- Prosody IM
-- Copyright (C) 2008-2011 Florian Zeitz
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- luacheck: ignore 113/setfenv 113/loadstring

local load = load;
local io_open = io.open;

local function envload(code, source, env)
	return load(code, source, nil, env);
end

local function envloadfile(file, env)
	local fh, err, errno = io_open(file);
	if not fh then return fh, err, errno; end
	local f, err = load(fh:lines(2048), "@" .. file, nil, env);
	fh:close();
	return f, err;
end

return { envload = envload, envloadfile = envloadfile };
