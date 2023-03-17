-- Allow for both require"util.foo" and require"prosody.util.foo" for a
-- transition period while we update all require calls.

if (...) == "prosody.loader" then
	if not package.path:find "prosody" then
		-- For require"util.foo" also look in paths equivalent to "prosody.util.foo"
		package.path = package.path:gsub("([^;]*)(?[^;]*)", "%1prosody/%2;%1%2");
		package.cpath = package.cpath:gsub("([^;]*)(?[^;]*)", "%1prosody/%2;%1%2");
	end
else
	-- When requiring "prosody.x", also look for "x"
	for i = #package.searchers, 1, -1 do
		local search = package.searchers[i];
		table.insert(package.searchers, i, function(module_name)
			local lib = module_name:match("^prosody%.(.*)$");
			if lib then
				return search(lib);
			end
		end)
	end
end

-- Look for already loaded module with or without prefix
setmetatable(package.loaded, {
	__index = function(loaded, module_name)
		local suffix = module_name:match("^prosody%.(.*)$");
		if suffix then
			return rawget(loaded, suffix);
		end
		local prefixed = rawget(loaded, "prosody." .. module_name);
		if prefixed ~= nil then
			return prefixed;
		end
	end;
})
