for i = #package.searchers, 1, -1 do
	local search = package.searchers[i];
	table.insert(package.searchers, i, function(module_name)
		local lib = module_name:match("^prosody%.(.*)$");
		if lib then
			return search(lib);
		end
	end)
end
