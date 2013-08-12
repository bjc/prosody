local log = require "util.logger".init("util.async");

local function runner_continue(thread)
	-- ASSUMPTION: runner is in 'waiting' state (but we don't have the runner to know for sure)
	if coroutine.status(thread) ~= "suspended" then -- This should suffice
		return false;
	end
	local ok, state, runner = coroutine.resume(thread);
	if not ok then
		local level = 0;
		while debug.getinfo(thread, level, "") do level = level + 1; end
		ok, runner = debug.getlocal(thread, level-1, 1);
		local error_handler = runner.watchers.error;
		if error_handler then error_handler(runner, debug.traceback(thread, state)); end
	elseif state == "ready" then
		-- If state is 'ready', it is our responsibility to update runner.state from 'waiting'.
		-- We also have to :run(), because the queue might have further items that will not be
		-- processed otherwise. FIXME: It's probably best to do this in a nexttick (0 timer).
		runner.state = "ready";
		runner:run();
	end
	return true;
end

local function waiter(num)
	local thread = coroutine.running();
	if not thread then
		error("Not running in an async context, see http://prosody.im/doc/developers/async");
	end
	num = num or 1;
	return function ()
		coroutine.yield("wait");
	end, function ()
		num = num - 1;
		if num == 0 then
			if not runner_continue(thread) then
				error("done() called without wait()!");
			end
		end
	end;
end

local runner_mt = {};
runner_mt.__index = runner_mt;

local function runner_create_thread(func, self)
	local thread = coroutine.create(function (self)
		while true do
			func(coroutine.yield("ready", self));
		end
	end);
	assert(coroutine.resume(thread, self)); -- Start it up, it will return instantly to wait for the first input
	return thread;
end

local empty_watchers = {};
local function runner(func, watchers, data)
	return setmetatable({ func = func, thread = false, state = "ready", notified_state = "ready",
		queue = {}, watchers = watchers or empty_watchers, data = data }
	, runner_mt);
end

function runner_mt:run(input)
	if input ~= nil then
		table.insert(self.queue, input);
	end
	if self.state ~= "ready" then
		return true, self.state, #self.queue;
	end

	local q, thread = self.queue, self.thread;
	if not thread or coroutine.status(thread) == "dead" then
		thread = runner_create_thread(self.func, self);
		self.thread = thread;
	end

	local n, state, err = #q, self.state, nil;
	self.state = "running";
	while n > 0 and state == "ready" do
		local consumed;
		for i = 1,n do
			local input = q[i];
			local ok, new_state = coroutine.resume(thread, input);
			if not ok then
				consumed, state, err = i, "ready", debug.traceback(thread, new_state);
				self.thread = nil;
				break;
			elseif new_state == "wait" then
				consumed, state = i, "waiting";
				break;
			end
		end
		if not consumed then consumed = n; end
		if q[n+1] ~= nil then
			n = #q;
		end
		for i = 1, n do
			q[i] = q[consumed+i];
		end
		n = #q;
	end
	self.state = state;
	if state ~= self.notified_state then
		self.notified_state = state;
		local handler = self.watchers[state];
		if handler then handler(self, err); end
	end
	return true, state, n;
end

function runner_mt:enqueue(input)
	table.insert(self.queue, input);
end

return { waiter = waiter, runner = runner };
