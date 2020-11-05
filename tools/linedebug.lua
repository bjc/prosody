local data = {}
local getinfo = debug.getinfo;
local function linehook(ev, li)
	local S = getinfo(2, "S");
	if S and S.source and S.source:match"^@" then
		local file = S.source:sub(2);
		local lines = data[file];
		if not lines then
			lines = {};
			data[file] = lines;
			for line in io.lines(file) do
				lines[#lines+1] = line;
			end
		end
		io.stderr:write(ev, " ", file, " ", li, " ", lines[li], "\n");
	end
end
debug.sethook(linehook, "l");
