
local config = require "core.configmanager";
local log = require "util.logger".init("stats");
local timer = require "util.timer";
local fire_event = prosody.events.fire_event;

local stats_config = config.get("*", "statistics_interval");
local stats_interval = tonumber(stats_config);
if stats_config and not stats_interval then
	log("error", "Invalid 'statistics_interval' setting, statistics will be disabled");
end

local stats_provider_config = config.get("*", "statistics_provider");
local stats_provider = stats_provider_config or "internal";

local builtin_providers = {
	internal = "util.statistics";
	statsd = "util.statsd";
};

if stats_provider:match("^library:") then
	stats_provider = stats_provider:match(":(.+)$");
else
	stats_provider = builtin_providers[stats_provider];
	if not stats_provider then
		log("error", "Unrecognized built-in statistics provider '%s', using internal instead", stats_provider_config);
		stats_provider = builtin_providers["internal"];
	end
end

local have_stats_provider, stats_lib = pcall(require, stats_provider);

local stats, stats_err;

if not have_stats_provider then
	stats, stats_err = nil, stats_lib;
else
	local stats_config = config.get("*", "statistics_config");
	stats, stats_err = stats_lib.new(stats_config);
end

if not stats then
	log("error", "Error loading statistics provider '%s': %s", stats_provider, stats_err);
end

local measure, collect;
local latest_stats = {};
local changed_stats = {};
local stats_extra = {};

if stats then
	function measure(type, name)
		local f = assert(stats[type], "unknown stat type: "..type);
		return f(name);
	end
end

if stats_interval then
	if stats.get_stats then
		log("debug", "Statistics collection is enabled every %d seconds", stats_interval);

		local mark_collection_start = measure("times", "stats.collection");
		local mark_processing_start = measure("times", "stats.processing");

		function collect()
			local mark_collection_done = mark_collection_start();
			fire_event("stats-update");
			changed_stats, stats_extra = {}, {};
			for stat_name, getter in pairs(stats.get_stats()) do
				local type, value, extra = getter();
				local old_value = latest_stats[stat_name];
				latest_stats[stat_name] = value;
				if value ~= old_value then
					changed_stats[stat_name] = value;
				end
				if extra then
					stats_extra[stat_name] = extra;
				end
			end
			mark_collection_done();
			local mark_processing_done = mark_processing_start();
			fire_event("stats-updated", { stats = latest_stats, changed_stats = changed_stats, stats_extra = stats_extra });
			mark_processing_done();
			return stats_interval;
		end
		timer.add_task(stats_interval, collect);
		prosody.events.add_handler("server-started", function () collect() end, -1);
	else
		log("error", "statistics_interval specified, but the selected statistics_provider (%s) does not support statistics collection", stats_provider_config or "internal");
	end
end

if not stats_interval and stats_provider == "util.statistics" then
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
	get_stats = function ()
		return latest_stats, changed_stats, stats_extra;
	end;
	get = function (name)
		return latest_stats[name], stats_extra[name];
	end;
};
