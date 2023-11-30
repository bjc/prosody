module:set_global();

local async = require("prosody.util.async");

local active_hosts = {}

function module.add_host(host_module)

	local last_run_times = host_module:open_store("cron", "map");
	active_hosts[host_module.host] = true;

	local function save_task(task, started_at)
		last_run_times:set(nil, task.id, started_at);
	end

	local function restore_task(task)
		if task.last == nil then
			task.last = last_run_times:get(nil, task.id);
		end
	end

	local function task_added(event)
		local task = event.item;
		if task.name == nil then
			task.name = task.when;
		end
		if task.id == nil then
			task.id = event.source.name .. "/" .. task.name:gsub("%W", "_"):lower();
		end
		task.period = host_module:get_option_period(task.id:gsub("/", "_") .. "_period", "1" .. task.when, 60, 86400 * 7 * 53);
		task.restore = restore_task;
		task.save = save_task;
		module:log("debug", "%s task %s added", task.when, task.id);
		return true
	end

	local function task_removed(event)
		local task = event.item;
		host_module:log("debug", "Task %s removed", task.id);
		return true
	end

	host_module:handle_items("task", task_added, task_removed, true);

	function host_module.unload()
		active_hosts[host_module.host] = nil;
	end
end

local function should_run(task, last)
	return not last or last + task.period * 0.995 <= os.time()
end

local function run_task(task)
	task:restore();
	if not should_run(task, task.last) then
		return
	end
	local started_at = os.time();
	task:run(started_at);
	task.last = started_at;
	task:save(started_at);
end

local task_runner = async.runner(run_task);
scheduled = module:add_timer(1, function()
	module:log("info", "Running periodic tasks");
	local delay = 3600;
	for host in pairs(active_hosts) do
		module:log("debug", "Running periodic tasks for host %s", host);
		for _, task in ipairs(module:context(host):get_host_items("task")) do
			task_runner:run(task);
		end
	end
	module:log("debug", "Wait %ds", delay);
	return delay
end);

module:add_item("shell-command", {
	section = "cron";
	section_desc = "View and manage recurring tasks";
	name = "tasks";
	desc = "View registered tasks";
	args = {};
	handler = function (self, filter_host)
		local format_table = require "prosody.util.human.io".table;
		local it = require "util.iterators";
		local row = format_table({
			{ title = "Host", width = "2p" };
			{ title = "Task", width = "3p" };
			{ title = "Desc", width = "3p" };
			{ title = "When", width = "1p" };
			{ title = "Last run", width = "20" };
		}, self.session.width);
		local print = self.session.print;
		print(row());
		for host in it.sorted_pairs(filter_host and { [filter_host]=true } or active_hosts) do
			for _, task in ipairs(module:context(host):get_host_items("task")) do
				print(row { host, task.id, task.name, task.when, task.last and os.date("%Y-%m-%d %R:%S", task.last) or "never" });
				--self.session.print(require "util.serialization".serialize(task, "debug"));
				--print("");
			end
		end
	end;
});
