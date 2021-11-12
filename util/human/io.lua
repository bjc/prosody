local array = require "util.array";

local function getchar(n)
	local stty_ret = os.execute("stty raw -echo 2>/dev/null");
	local ok, char;
	if stty_ret == true or stty_ret == 0 then
		ok, char = pcall(io.read, n or 1);
		os.execute("stty sane");
	else
		ok, char = pcall(io.read, "*l");
		if ok then
			char = char:sub(1, n or 1);
		end
	end
	if ok then
		return char;
	end
end

local function getline()
	local ok, line = pcall(io.read, "*l");
	if ok then
		return line;
	end
end

local function getpass()
	local stty_ret, _, status_code = os.execute("stty -echo 2>/dev/null");
	if status_code then -- COMPAT w/ Lua 5.1
		stty_ret = status_code;
	end
	if stty_ret ~= 0 then
		io.write("\027[08m"); -- ANSI 'hidden' text attribute
	end
	local ok, pass = pcall(io.read, "*l");
	if stty_ret == 0 then
		os.execute("stty sane");
	else
		io.write("\027[00m");
	end
	io.write("\n");
	if ok then
		return pass;
	end
end

local function show_yesno(prompt)
	io.write(prompt, " ");
	local choice = getchar():lower();
	io.write("\n");
	if not choice:match("%a") then
		choice = prompt:match("%[.-(%U).-%]$");
		if not choice then return nil; end
	end
	return (choice == "y");
end

local function read_password()
	local password;
	while true do
		io.write("Enter new password: ");
		password = getpass();
		if not password then
			print("No password - cancelled");
			return;
		end
		io.write("Retype new password: ");
		if getpass() ~= password then
			if not show_yesno [=[Passwords did not match, try again? [Y/n]]=] then
				return;
			end
		else
			break;
		end
	end
	return password;
end

local function show_prompt(prompt)
	io.write(prompt, " ");
	local line = getline();
	line = line and line:gsub("\n$","");
	return (line and #line > 0) and line or nil;
end

local function printf(fmt, ...)
	print(fmt:format(...));
end

local function padright(s, width)
	return s..string.rep(" ", width-#s);
end

local function padleft(s, width)
	return string.rep(" ", width-#s)..s;
end

local function new_table(col_specs, max_width)
	max_width = max_width or tonumber(os.getenv("COLUMNS")) or 80;
	local separator = " | ";

	local widths = {};
	local total_width = max_width - #separator * (#col_specs-1);
	local free_width = total_width;
	-- Calculate width of fixed-size columns
	for i = 1, #col_specs do
		local width = col_specs[i].width or "0";
		if not(type(width) == "string" and width:sub(-1) == "%") then
			local title = col_specs[i].title;
			width = math.max(tonumber(width), title and (#title+1) or 0);
			widths[i] = width;
			free_width = free_width - width;
			if i > 1 then
				free_width = free_width - #separator;
			end
		end
	end
	-- Calculate width of %-based columns
	for i = 1, #col_specs do
		if not widths[i] then
			local pc_width = tonumber((col_specs[i].width:gsub("%%$", "")));
			widths[i] = math.floor(free_width*(pc_width/100));
		end
	end

	return function (row)
		local titles;
		if not row then
			titles, row = true, array.pluck(col_specs, "title", "");
		end
		local output = {};
		for i, column in ipairs(col_specs) do
			local width = widths[i];
			local v = row[not titles and column.key or i];
			if not titles and column.mapper then
				v = column.mapper(v, row);
			end
			if v == nil then
				v = column.default or "";
			else
				v = tostring(v);
			end
			if #v < width then
				if column.align == "right" then
					v = padleft(v, width);
				else
					v = padright(v, width);
				end
			elseif #v > width then
				v = v:sub(1, width-1) .. "…";
			end
			table.insert(output, v);
		end
		return table.concat(output, separator);
	end;
end

return {
	getchar = getchar;
	getline = getline;
	getpass = getpass;
	show_yesno = show_yesno;
	read_password = read_password;
	show_prompt = show_prompt;
	printf = printf;
	padleft = padleft;
	padright = padright;
	table = new_table;
};
