-- Variables ending with these names will not
-- have their values printed ('password' includes
-- 'new_password', etc.)
local censored_names = {
	password = true;
	passwd = true;
	pass = true;
	pwd = true;
};
local optimal_line_length = 65;

local termcolours = require "util.termcolours";
local getstring = termcolours.getstring;
local styles;
do
	_ = termcolours.getstyle;
	styles = {
		boundary_padding = _("bright");
		filename         = _("bright", "blue");
		level_num        = _("green");
		funcname         = _("yellow");
		location         = _("yellow");
	};
end
module("debugx", package.seeall);

function get_locals_table(thread, level)
	if not thread then
		level = level + 1; -- Skip this function itself
	end
	local locals = {};
	for local_num = 1, math.huge do
		local name, value = debug.getlocal(thread, level, local_num);
		if not name then break; end
		table.insert(locals, { name = name, value = value });
	end
	return locals;
end

function get_upvalues_table(func)
	local upvalues = {};
	if func then
		for upvalue_num = 1, math.huge do
			local name, value = debug.getupvalue(func, upvalue_num);
			if not name then break; end
			table.insert(upvalues, { name = name, value = value });
		end
	end
	return upvalues;
end

function string_from_var_table(var_table, max_line_len, indent_str)
	local var_string = {};
	local col_pos = 0;
	max_line_len = max_line_len or math.huge;
	indent_str = "\n"..(indent_str or "");
	for _, var in ipairs(var_table) do
		local name, value = var.name, var.value;
		if name:sub(1,1) ~= "(" then
			if type(value) == "string" then
				if censored_names[name:match("%a+$")] then
					value = "<hidden>";
				else
					value = ("%q"):format(value);
				end
			else
				value = tostring(value);
			end
			if #value > max_line_len then
				value = value:sub(1, max_line_len-3).."…";
			end
			local str = ("%s = %s"):format(name, tostring(value));
			col_pos = col_pos + #str;
			if col_pos > max_line_len then
				table.insert(var_string, indent_str);
				col_pos = 0;
			end
			table.insert(var_string, str);
		end
	end
	if #var_string == 0 then
		return nil;
	else
		return "{ "..table.concat(var_string, ", "):gsub(indent_str..", ", indent_str).." }";
	end
end

function get_traceback_table(thread, start_level)
	local levels = {};
	for level = start_level, math.huge do
		local info;
		if thread then
			info = debug.getinfo(thread, level);
		else
			info = debug.getinfo(level+1);
		end
		if not info then break; end

		levels[(level-start_level)+1] = {
			level = level;
			info = info;
			locals = get_locals_table(thread, level+(thread and 0 or 1));
			upvalues = get_upvalues_table(info.func);
		};
	end
	return levels;
end

function traceback(...)
	local ok, ret = pcall(_traceback, ...);
	if not ok then
		return "Error in error handling: "..ret;
	end
	return ret;
end

local function build_source_boundary_marker(last_source_desc)
	local padding = string.rep("-", math.floor(((optimal_line_length - 6) - #last_source_desc)/2));
	return getstring(styles.boundary_padding, "v"..padding).." "..getstring(styles.filename, last_source_desc).." "..getstring(styles.boundary_padding, padding..(#last_source_desc%2==0 and "-v" or "v "));
end

function _traceback(thread, message, level)

	-- Lua manual says: debug.traceback ([thread,] [message [, level]])
	-- I fathom this to mean one of:
	-- ()
	-- (thread)
	-- (message, level)
	-- (thread, message, level)

	if thread == nil then -- Defaults
		thread, message, level = coroutine.running(), message, level;
	elseif type(thread) == "string" then
		thread, message, level = coroutine.running(), thread, message;
	elseif type(thread) ~= "thread" then
		return nil; -- debug.traceback() does this
	end

	level = level or 0;

	message = message and (message.."\n") or "";

	-- +3 counts for this function, and the pcall() and wrapper above us, the +1... I don't know.
	local levels = get_traceback_table(thread, level+(thread == nil and 4 or 0));

	local last_source_desc;

	local lines = {};
	for nlevel, level in ipairs(levels) do
		local info = level.info;
		local line = "...";
		local func_type = info.namewhat.." ";
		local source_desc = (info.short_src == "[C]" and "C code") or info.short_src or "Unknown";
		if func_type == " " then func_type = ""; end;
		if info.short_src == "[C]" then
			line = "[ C ] "..func_type.."C function "..getstring(styles.location, (info.name and ("%q"):format(info.name) or "(unknown name)"));
		elseif info.what == "main" then
			line = "[Lua] "..getstring(styles.location, info.short_src.." line "..info.currentline);
		else
			local name = info.name or " ";
			if name ~= " " then
				name = ("%q"):format(name);
			end
			if func_type == "global " or func_type == "local " then
				func_type = func_type.."function ";
			end
			line = "[Lua] "..getstring(styles.location, info.short_src.." line "..info.currentline).." in "..func_type..getstring(styles.funcname, name).." (defined on line "..info.linedefined..")";
		end
		if source_desc ~= last_source_desc then -- Venturing into a new source, add marker for previous
			last_source_desc = source_desc;
			table.insert(lines, "\t "..build_source_boundary_marker(last_source_desc));
		end
		nlevel = nlevel-1;
		table.insert(lines, "\t"..(nlevel==0 and ">" or " ")..getstring(styles.level_num, "("..nlevel..") ")..line);
		local npadding = (" "):rep(#tostring(nlevel));
		if level.locals then
			local locals_str = string_from_var_table(level.locals, optimal_line_length, "\t            "..npadding);
			if locals_str then
				table.insert(lines, "\t    "..npadding.."Locals: "..locals_str);
			end
		end
		local upvalues_str = string_from_var_table(level.upvalues, optimal_line_length, "\t            "..npadding);
		if upvalues_str then
			table.insert(lines, "\t    "..npadding.."Upvals: "..upvalues_str);
		end
	end

--	table.insert(lines, "\t "..build_source_boundary_marker(last_source_desc));

	return message.."stack traceback:\n"..table.concat(lines, "\n");
end

function use()
	debug.traceback = traceback;
end

return _M;
