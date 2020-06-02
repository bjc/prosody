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
	print(msg:format(...));
end

return {
	getchar = getchar;
	getline = getline;
	getpass = getpass;
	show_yesno = show_yesno;
	read_password = read_password;
	show_prompt = show_prompt;
	printf = printf;
};
