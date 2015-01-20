
local stats = require "util.statistics".new();
local config = require "core.configmanager";
local log = require "util.logger".init("stats");
local timer = require "util.timer";
local fire_event = prosody.events.fire_event;

local stats_config = config.get("*", "statistics_interval");
local stats_interval = tonumber(stats_config);
if stats_config and not stats_interval then
	log("error", "Invalid 'statistics_interval' setting, statistics will be disabled");
end

local measure, collect;
local latest_stats = {};
local changed_stats = {};
local stats_extra = {};

if stats_interval then
	log("debug", "Statistics collection is enabled every %d seconds", stats_interval);
	function measure(type, name)
		local f = assert(stats[type], "unknown stat type: "..type);
		return f(name);
	end

	local mark_collection_start = measure("duration", "stats.collection_time");
	local mark_processing_start = measure("duration", "stats.processing_time");

	function collect()
		local mark_collection_done = mark_collection_start();
		changed_stats, stats_extra = {}, {};
		for name, getter in pairs(stats.get_stats()) do
			local type, value, extra = getter();
			local stat_name = name..":"..type;
			local old_value = latest_stats[stat_name];
			latest_stats[stat_name] = value;
			if value ~= old_value then
				changed_stats[stat_name] = value;
			end
			if extra then
				print(stat_name, extra)
				stats_extra[stat_name] = extra;
				if type == "duration" then
					local rate = extra.rate;
					local rate_name = name..":rate";
					latest_stats[rate_name] = rate;
					changed_stats[rate_name] = rate;
				end
			end
		end
		mark_collection_done();
		local mark_processing_done = mark_processing_start();
		fire_event("stats-updated", { stats = latest_stats, changed_stats = changed_stats, stats_extra = stats_extra });
		mark_processing_done();
		return stats_interval;
	end

	timer.add_task(stats_interval, collect);
else
	log("debug", "Statistics collection is disabled");
	-- nop
	function measure()
		return measure;
	end
	function collect()
	end
end

return {
	measure = measure;
	collect = collect;
	get_stats = function ()
		return latest_stats, changed_stats, stats_extra;
	end;
};
