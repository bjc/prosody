
local verbosity = tonumber(arg[1]) or 2;

function assert_equal(a, b)
	if not (a == b) then
		error(getfenv(2).__unit.."assert_equal failed: "..tostring(a).." ~= "..tostring(b), 2);
	elseif verbosity >= 4 then
		print("assert_equal succeeded: "..tostring(a).." == "..tostring(b));
	end
end

function dotest(unitname)
	local tests = setmetatable({}, { __index = _G });
	tests.__unit = unitname;
	local chunk, err = loadfile("test_"..unitname:gsub("%.", "_")..".lua");
	if not chunk then
		print("WARNING: ", "Failed to load tests for "..unitname, err);
		return;
	end

	setfenv(chunk, tests);
	local success, err = pcall(chunk);
	if not success then
		print("WARNING: ", "Failed to initialise tests for "..unitname, err);
		return;
	end
	
	local unit = setmetatable({}, { __index = setmetatable({ module = function () end }, { __index = _G }) });

	local chunk, err = loadfile("../"..unitname:gsub("%.", "/")..".lua");
	if not chunk then
		print("WARNING: ", "Failed to load module: "..unitname, err);
		return;
	end

	setfenv(chunk, unit);
	local success, err = pcall(chunk);
	if not success then
		print("WARNING: ", "Failed to initialise module: "..unitname, err);
		return;
	end
	
	for name, f in pairs(unit) do
		if type(f) ~= "function" then
			if verbosity >= 3 then
				print("INFO: ", "Skipping "..unitname.."."..name.." because it is not a function");
			end
		elseif type(tests[name]) ~= "function" then
			if verbosity >= 1 then
				print("WARNING: ", unitname.."."..name.." has no test!");
			end
		else
			local success, ret = pcall(tests[name], f, unit);
			if not success then
				print("TEST FAILED: ", unitname, name, ret);
			elseif verbosity >= 2 then
				print("TEST SUCCEEDED: ", unitname, name);
			end
		end
	end
end

dotest "util.jid"

