local array = require "prosody.util.array";
local pposix = require "prosody.util.pposix";
local utf8 = rawget(_G, "utf8") or require"prosody.util.encodings".utf8;
local len = utf8.len or function(s)
	local _, count = s:gsub("[%z\001-\127\194-\253][\128-\191]*", "");
	return count;
end;

local function getchar(n)
	local stty_ret = os.execute("stty raw -echo 2>/dev/null");
	local ok, char;
	if stty_ret then
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
	local stty_ret = os.execute("stty -echo 2>/dev/null");
	if not stty_ret then
		io.write("\027[08m"); -- ANSI 'hidden' text attribute
	end
	local ok, pass = pcall(io.read, "*l");
	if stty_ret then
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
	return s..string.rep(" ", width-len(s));
end

local function padleft(s, width)
	return string.rep(" ", width-len(s))..s;
end

local pat = "[%z\001-\127\194-\253][\128-\191]*";
local function utf8_cut(s, pos)
	return s:match("^"..pat:rep(pos)) or s;
end

if utf8.len and utf8.offset then
	function utf8_cut(s, pos)
		return s:sub(1, utf8.offset(s, pos+1)-1);
	end
end

local function term_width(default)
	local env_cols = tonumber(os.getenv "COLUMNS");
	if env_cols then return env_cols; end
	if not pposix.isatty(io.stdout) then
		return default;
	end
	local stty = io.popen("stty -a");
	if not stty then return default; end
	local result = stty:read("*a");
	if result then
		result = result:match("%f[%w]columns[ =]*(%d+)");
	end
	stty:close();
	return tonumber(result or default);
end

local function ellipsis(s, width)
	if len(s) <= width then return s; end
	if width <= 1 then return "…"; end
	return utf8_cut(s, width - 1) .. "…";
end

local function new_table(col_specs, max_width)
	max_width = max_width or term_width(80);
	local separator = " | ";

	local widths = {};
	local total_width = max_width - #separator * (#col_specs-1);
	local free_width = total_width;
	-- Calculate width of fixed-size columns
	for i = 1, #col_specs do
		local width = col_specs[i].width or "0";
		if not (type(width) == "string" and width:match("[p%%]$")) then
			local title = col_specs[i].title;
			width = math.max(tonumber(width), title and (#title+1) or 0);
			widths[i] = width;
			free_width = free_width - width;
		end
	end

	-- Calculate width of proportional columns
	local total_proportional_width = 0;
	for i = 1, #col_specs do
		if not widths[i] then
			local width_spec = col_specs[i].width:match("([%d%.]+)[p%%]");
			total_proportional_width = total_proportional_width + tonumber(width_spec);
		end
	end

	for i = 1, #col_specs do
		if not widths[i] then
			local width_spec = col_specs[i].width:match("([%d%.]+)[p%%]");
			local rel_width = tonumber(width_spec);
			widths[i] = math.floor(free_width*(rel_width/total_proportional_width));
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
				v = column.mapper(v, row, width, column);
			end
			if v == nil then
				v = column.default or "";
			else
				v = tostring(v);
			end
			if len(v) < width then
				if column.align == "right" then
					v = padleft(v, width);
				else
					v = padright(v, width);
				end
			elseif len(v) > width then
				v = (column.ellipsis or ellipsis)(v, width);
			end
			table.insert(output, v);
		end
		return table.concat(output, separator);
	end, max_width;
end

local day = 86400;
local multipliers = {
	d = day, w = day * 7, mon = 31 * day, y = 365.2425 * day;
	s = 1, min = 60, h = 3600, ho = 3600
};

local function parse_duration(duration_string)
	local n, m = duration_string:lower():match("(%d+)%s*([smhdwy]?[io]?n?)");
	if not n or not multipliers[m] then return nil; end
	return tonumber(n) * ( multipliers[m] or 1 );
end

local multipliers_lax = setmetatable({
	m = multipliers.mon;
	mo = multipliers.mon;
	mi = multipliers.min;
}, { __index = multipliers });

local function parse_duration_lax(duration_string)
	local n, m = duration_string:lower():match("(%d+)%s*([smhdwy]?[io]?)");
	if not n then return nil; end
	return tonumber(n) * ( multipliers_lax[m] or 1 );
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
	term_width = term_width;
	ellipsis = ellipsis;
	table = new_table;
	parse_duration = parse_duration;
	parse_duration_lax = parse_duration_lax;
};
