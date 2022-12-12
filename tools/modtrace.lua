-- Trace module calls and method calls on created objects
--
-- Very rough and for debugging purposes only. It makes many
-- assumptions and there are many ways it could fail.
--
-- Example use:
--
--   local dbuffer = require "tools.modtrace".trace("util.dbuffer");
--

local t_pack = table.pack;
local serialize = require "util.serialization".serialize;
local unpack = table.unpack;
local set = require "util.set";

local serialize_cfg = {
	preset = "oneline";
	freeze = true;
	fatal = false;
	fallback = function (v) return "<"..tostring(v)..">" end;
};

local function stringify_value(v)
	if type(v) == "string" and #v > 20 then
		return ("<string(%d)>"):format(#v);
	elseif type(v) == "function" then
		return tostring(v);
	end
	return serialize(v, serialize_cfg);
end

local function stringify_params(...)
	local n = select("#", ...);
	local r = {};
	for i = 1, n do
		table.insert(r, stringify_value((select(i, ...))));
	end
	return table.concat(r, ", ");
end

local function stringify_result(ret)
	local r = {};
	for i = 1, ret.n do
		table.insert(r, stringify_value(ret[i]));
	end
	return table.concat(r, ", ");
end

local function stringify_call(method_name, ...)
	return ("%s(%s)"):format(method_name, stringify_params(...));
end

local function wrap_method(original_obj, original_method, method_name)
	method_name = ("<%s>:%s"):format(getmetatable(original_obj).__name or "object", method_name);
	return function (new_obj_self, ...)
		local opts = new_obj_self._modtrace_opts;
		local f = opts.output or io.stderr;
		f:write(stringify_call(method_name, ...));
		local ret = t_pack(original_method(original_obj, ...));
		if ret.n > 0 then
			f:write(" = ", stringify_result(ret), "\n");
		else
			f:write("\n");
		end
		return unpack(ret, 1, ret.n);
	end;
end

local function wrap_function(original_function, function_name, opts)
	local f = opts.output or io.stderr;
	return function (...)
		f:write(stringify_call(function_name, ...));
		local ret = t_pack(original_function(...));
		if ret.n > 0 then
			f:write(" = ", stringify_result(ret), "\n");
		else
			f:write("\n");
		end
		return unpack(ret, 1, ret.n);
	end;
end

local function wrap_metamethod(name, method)
	if name == "__index" then
		return function (new_obj, k)
			local original_method;
			if type(method) == "table" then
				original_method = new_obj._modtrace_original_obj[k];
			else
				original_method = method(new_obj._modtrace_original_obj, k);
			end
			if original_method == nil then
				return nil;
			end
			return wrap_method(new_obj._modtrace_original_obj, original_method, k);
		end;
	end
	return function (new_obj, ...)
		return method(new_obj._modtrace_original_obj, ...);
	end;
end

local function wrap_mt(original_mt)
	local new_mt = {};
	for k, v in pairs(original_mt) do
		new_mt[k] = wrap_metamethod(k, v);
	end
	return new_mt;
end

local function wrap_obj(original_obj, opts)
	local new_mt = wrap_mt(getmetatable(original_obj));
	return setmetatable({_modtrace_original_obj = original_obj, _modtrace_opts = opts}, new_mt);
end

local function wrap_new(original_new, function_name, opts)
	local f = opts.output or io.stderr;
	return function (...)
		f:write(stringify_call(function_name, ...));
		local ret = t_pack(original_new(...));
		local obj = ret[1];

		if ret.n == 1 and type(ret[1]) == "table" then
			f:write(" = <", getmetatable(ret[1]).__name or "object", ">", "\n");
		elseif ret.n > 0 then
			f:write(" = ", stringify_result(ret), "\n");
		else
			f:write("\n");
		end

		if obj then
			ret[1] = wrap_obj(obj, opts);
		end
		return unpack(ret, 1, ret.n);
	end;
end

local function trace(module, opts)
	if type(module) == "string" then
		module = require(module);
	end
	opts = opts or {};
	local new_methods = set.new(opts.new_methods or {"new"});
	local fake_module = setmetatable({}, {
		__index = function (_, k)
			if new_methods:contains(k) then
				return wrap_new(module[k], k, opts);
			else
				return wrap_function(module[k], k, opts);
			end
		end;
	});
	return fake_module;
end

return {
	wrap = trace;
	trace = trace;
}
