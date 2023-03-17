local promise_methods = {};
local promise_mt = { __name = "promise", __index = promise_methods };

local xpcall = require "prosody.util.xpcall".xpcall;
local unpack = table.unpack;

function promise_mt:__tostring()
	return  "promise (" .. (self._state or "invalid") .. ")";
end

local function is_promise(o)
	local mt = getmetatable(o);
	return mt == promise_mt;
end

local function wrap_handler(f, resolve, reject, default)
	if not f then
		return default;
	end
	return function (param)
		local ok, ret = xpcall(f, debug.traceback, param);
		if ok then
			resolve(ret);
		else
			reject(ret);
		end
		return true;
	end;
end

local function next_pending(self, on_fulfilled, on_rejected, resolve, reject)
	table.insert(self._pending_on_fulfilled, wrap_handler(on_fulfilled, resolve, reject, resolve));
	table.insert(self._pending_on_rejected, wrap_handler(on_rejected, resolve, reject, reject));
end

local function next_fulfilled(promise, on_fulfilled, on_rejected, resolve, reject) -- luacheck: ignore 212/on_rejected
	wrap_handler(on_fulfilled, resolve, reject, resolve)(promise.value);
end

local function next_rejected(promise, on_fulfilled, on_rejected, resolve, reject) -- luacheck: ignore 212/on_fulfilled
	wrap_handler(on_rejected, resolve, reject, reject)(promise.reason);
end

local function promise_settle(promise, new_state, new_next, cbs, value)
	if promise._state ~= "pending" then
		return;
	end
	promise._state = new_state;
	promise._next = new_next;
	for _, cb in ipairs(cbs) do
		cb(value);
	end
	-- No need to keep references to callbacks
	promise._pending_on_fulfilled = nil;
	promise._pending_on_rejected = nil;
	return true;
end

local function new_resolve_functions(p)
	local function _resolve(v)
		if is_promise(v) then
			v:next(new_resolve_functions(p));
		elseif promise_settle(p, "fulfilled", next_fulfilled, p._pending_on_fulfilled, v) then
			p.value = v;
		end

	end
	local function _reject(e)
		if promise_settle(p, "rejected", next_rejected, p._pending_on_rejected, e) then
			p.reason = e;
		end
	end
	return _resolve, _reject;
end

local next_tick = function (f)
	f();
end

local function new(f)
	local p = setmetatable({ _state = "pending", _next = next_pending, _pending_on_fulfilled = {}, _pending_on_rejected = {} }, promise_mt);
	if f then
		next_tick(function()
			local resolve, reject = new_resolve_functions(p);
			local ok, ret = xpcall(f, debug.traceback, resolve, reject);
			if not ok and p._state == "pending" then
				reject(ret);
			end
		end);
	end
	return p;
end

local function all(promises)
	return new(function (resolve, reject)
		local settled, results, loop_finished = 0, {}, false;
		local total = 0;
		for k, v in pairs(promises) do
			if is_promise(v) then
				total = total + 1;
				v:next(function (value)
					results[k] = value;
					settled = settled + 1;
					if settled == total and loop_finished then
						resolve(results);
					end
				end, reject);
			else
				results[k] = v;
			end
		end
		loop_finished = true;
		if settled == total then
			resolve(results);
		end
	end);
end

local function all_settled(promises)
	return new(function (resolve)
		local settled, results, loop_finished = 0, {}, false;
		local total = 0;
		for k, v in pairs(promises) do
			if is_promise(v) then
				total = total + 1;
				v:next(function (value)
					results[k] = { status = "fulfilled", value = value };
					settled = settled + 1;
					if settled == total and loop_finished then
						resolve(results);
					end
				end, function (e)
					results[k] = { status = "rejected", reason = e };
					settled = settled + 1;
					if settled == total and loop_finished then
						resolve(results);
					end
				end);
			else
				results[k] = v;
			end
		end
		loop_finished = true;
		if settled == total then
			resolve(results);
		end
	end);
end

local function join(handler, ...)
	local promises, n = { ... }, select("#", ...);
	return all(promises):next(function (results)
		return handler(unpack(results, 1, n));
	end);
end

local function race(promises)
	return new(function (resolve, reject)
		for i = 1, #promises do
			promises[i]:next(resolve, reject);
		end
	end);
end

local function resolve(v)
	return new(function (_resolve)
		_resolve(v);
	end);
end

local function reject(v)
	return new(function (_, _reject)
		_reject(v);
	end);
end

local function try(f)
	return resolve():next(function () return f(); end);
end

function promise_methods:next(on_fulfilled, on_rejected)
	return new(function (resolve, reject) --luacheck: ignore 431/resolve 431/reject
		self:_next(on_fulfilled, on_rejected, resolve, reject);
	end);
end

function promise_methods:catch(on_rejected)
	return self:next(nil, on_rejected);
end

function promise_methods:finally(on_finally)
	local function _on_finally(value) on_finally(); return value; end
	local function _on_catch_finally(err) on_finally(); return reject(err); end
	return self:next(_on_finally, _on_catch_finally);
end

return {
	new = new;
	resolve = resolve;
	join = join;
	reject = reject;
	all = all;
	all_settled = all_settled;
	race = race;
	try = try;
	is_promise = is_promise;
	set_nexttick = function(new_next_tick) next_tick = new_next_tick; end;
}
