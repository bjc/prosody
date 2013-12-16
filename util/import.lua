-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local t_insert = table.insert;
function import(module, ...)
	local m = package.loaded[module] or require(module);
	if type(m) == "table" and ... then
		local ret = {};
		for _, f in ipairs{...} do
			t_insert(ret, m[f]);
		end
		return unpack(ret);
	end
	return m;
end
