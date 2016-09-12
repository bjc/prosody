
local config = require "core.configmanager";
local log = require "util.logger".init("stats");
local timer = require "util.timer";
local fire_event = prosody.events.fire_event;

local stats_interval_config = config.get("*", "statistics_interval");
local stats_interval = tonumber(stats_interval_config);
if stats_interval_config and not stats_interval then
	log("error", "Invalid 'statistics_interval' setting, statistics will be disabled");
end

local stats_provider_name;
local stats_provider_config = config.get("*", "statistics");
local stats_provider = stats_provider_config;

if not stats_provider and stats_interval then
	stats_provider = "internal";
elseif stats_provider and not stats_interval then
	stats_interval = 60;
end

local builtin_providers = {
	internal = "util.statistics";
	statsd = "util.statsd";
};


local stats, stats_err = false, nil;

if stats_provider then
	if stats_provider:sub(1,1) == ":" then
		stats_provider = stats_provider:sub(2);
		stats_provider_name = "external "..stats_provider;
	elseif stats_provider then
		stats_provider_name = "built-in "..stats_provider;
		stats_provider = builtin_providers[stats_provider];
		if not stats_provider then
			log("error", "Unrecognized statistics provider '%s', statistics will be disabled", stats_provider_config);
		end
	end

	local have_stats_provider, stats_lib = pcall(require, stats_provider);
	if not have_stats_provider then
		stats, stats_err = nil, stats_lib;
	else
		local stats_config = config.get("*", "statistics_config");
		stats, stats_err = stats_lib.new(stats_config);
		stats_provider_name = stats_lib._NAME or stats_provider_name;
	end
end

if stats == nil then
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

	if stats_interval then
		log("debug", "Statistics enabled using %s provider, collecting every %d seconds", stats_provider_name, stats_interval);

		local mark_collection_start = measure("times", "stats.collection");
		local mark_processing_start = measure("times", "stats.processing");

		function collect()
			local mark_collection_done = mark_collection_start();
			fire_event("stats-update");
			mark_collection_done();

			if stats.get_stats then
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
				local mark_processing_done = mark_processing_start();
				fire_event("stats-updated", { stats = latest_stats, changed_stats = changed_stats, stats_extra = stats_extra });
				mark_processing_done();
			end
			return stats_interval;
		end
		timer.add_task(stats_interval, collect);
		prosody.events.add_handler("server-started", function () collect() end, -1);
	else
		log("debug", "Statistics enabled using %s provider, collection is disabled", stats_provider_name);
	end
else
	log("debug", "Statistics disabled");
	function measure() return measure; end
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
