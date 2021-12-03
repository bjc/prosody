module:set_global();

local async = require("util.async");
local datetime = require("util.datetime");

local periods = { hourly = 3600; daily = 86400 }

local active_hosts = {}

function module.add_host(host_module)

	local last_run_times = host_module:open_store("cron", "map");
	active_hosts[host_module.host] = true;

	local function save_task(task, started_at) last_run_times:set(nil, task.id, started_at); end

	local function task_added(event)
		local task = event.item;
		if task.name == nil then task.name = task.when; end
		if task.id == nil then task.id = event.source.name .. "/" .. task.name:gsub("%W", "_"):lower(); end
		if task.last == nil then task.last = last_run_times:get(nil, task.id); end
		task.save = save_task;
		module:log("debug", "%s task %s added, last run %s", task.when, task.id,
			task.last and datetime.datetime(task.last) or "never");
		if task.last == nil then
			local now = os.time();
			task.last = now - now % periods[task.when];
		end
		return true
	end

	local function task_removed(event)
		local task = event.item;
		host_module:log("debug", "Task %s removed", task.id);
		return true
	end

	host_module:handle_items("task", task_added, task_removed, true);

	function host_module.unload() active_hosts[host_module.host] = nil; end
end

local function should_run(when, last) return not last or last + periods[when] <= os.time() end

local function run_task(task)
	local started_at = os.time();
	task:run(started_at);
	task:save(started_at);
end

local task_runner = async.runner(run_task);
module:add_timer(1, function()
	module:log("info", "Running periodic tasks");
	local delay = 3600;
	for host in pairs(active_hosts) do
		module:log("debug", "Running periodic tasks for host %s", host);
		for _, task in ipairs(module:context(host):get_host_items("task")) do
			module:log("debug", "Considering %s task %s (%s)", task.when, task.id, task.run);
			if should_run(task.when, task.last) then task_runner:run(task); end
		end
	end
	module:log("debug", "Wait %ds", delay);
	return delay
end);
