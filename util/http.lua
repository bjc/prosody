-- Prosody IM
-- Copyright (C) 2013 Florian Zeitz
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local http = {};

function http.contains_token(field, token)
	field = ","..field:gsub("[ \t]", ""):lower()..",";
	return field:find(","..token:lower()..",", 1, true) ~= nil;
end

return http;
