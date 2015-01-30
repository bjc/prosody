local t_sort = table.sort
local m_floor = math.floor;
local time = require "socket".gettime;

local function nop_function() end

local function percentile(arr, length, pc)
	local n = pc/100 * (length + 1);
	local k, d = m_floor(n), n%1;
	if k == 0 then
		return arr[1] or 0;
	elseif k >= length then
		return arr[length];
	end
	return arr[k] + d*(arr[k+1] - arr[k]);
end

local function new_registry(config)
	config = config or {};
	local duration_sample_interval = config.duration_sample_interval or 5;
	local duration_max_samples = config.duration_max_stored_samples or 5000;

	local function get_distribution_stats(events, n_actual_events, since, new_time, units)
		local n_stored_events = #events;
		t_sort(events);
		local sum = 0;
		for i = 1, n_stored_events do
			sum = sum + events[i];
		end

		return {
			samples = events;
			sample_count = n_stored_events;
			count = n_actual_events,
			rate = n_actual_events/(new_time-since);
			average = n_stored_events > 0 and sum/n_stored_events or 0,
			min = events[1] or 0,
			max = events[n_stored_events] or 0,
			units = units,
		};
	end


	local registry = {};
	local methods;
	methods = {
		amount = function (name, initial)
			local v = initial or 0;
			registry[name..":amount"] = function () return "amount", v; end
			return function (new_v) v = new_v; end
		end;
		counter = function (name, initial)
			local v = initial or 0;
			registry[name..":amount"] = function () return "amount", v; end
			return function (delta)
				v = v + delta;
			end;
		end;
		rate = function (name)
			local since, n = time(), 0;
			registry[name..":rate"] = function ()
				local t = time();
				local stats = {
					rate = n/(t-since);
					count = n;
				};
				since, n = t, 0;
				return "rate", stats.rate, stats;
			end;
			return function ()
				n = n + 1;
			end;
		end;
		distribution = function (name, unit, type)
			type = type or "distribution";
			local events, last_event = {}, 0;
			local n_actual_events = 0;
			local since = time();

			registry[name..":"..type] = function ()
				local new_time = time();
				local stats = get_distribution_stats(events, n_actual_events, since, new_time, unit);
				events, last_event = {}, 0;
				n_actual_events = 0;
				since = new_time;
				return type, stats.average, stats;
			end;

			return function (value)
				n_actual_events = n_actual_events + 1;
				if n_actual_events%duration_sample_interval > 0 then
					last_event = (last_event%duration_max_samples) + 1;
					events[last_event] = value;
				end
			end;
		end;
		sizes = function (name)
			return methods.distribution(name, "bytes", "size");
		end;
		times = function (name)
			local events, last_event = {}, 0;
			local n_actual_events = 0;
			local since = time();

			registry[name..":duration"] = function ()
				local new_time = time();
				local stats = get_distribution_stats(events, n_actual_events, since, new_time, "seconds");
				events, last_event = {}, 0;
				n_actual_events = 0;
				since = new_time;
				return "duration", stats.average, stats;
			end;

			return function ()
				n_actual_events = n_actual_events + 1;
				if n_actual_events%duration_sample_interval > 0 then
					return nop_function;
				end

				local start_time = time();
				return function ()
					local end_time = time();
					local duration = end_time - start_time;
					last_event = (last_event%duration_max_samples) + 1;
					events[last_event] = duration;
				end
			end;
		end;

		get_stats = function ()
			return registry;
		end;
	};
	return methods;
end

return {
	new = new_registry;
	get_histogram = function (duration, n_buckets)
		n_buckets = n_buckets or 100;
		local events, n_events = duration.samples, duration.sample_count;
		if not (events and n_events) then
			return nil, "not a valid distribution stat";
		end
		local histogram = {};

		for i = 1, 100, 100/n_buckets do
			histogram[i] = percentile(events, n_events, i);
		end
		return histogram;
	end;

	get_percentile = function (duration, pc)
		local events, n_events = duration.samples, duration.sample_count;
		if not (events and n_events) then
			return nil, "not a valid distribution stat";
		end
		return percentile(events, n_events, pc);
	end;
}
