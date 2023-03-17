
local config = require "prosody.core.configmanager";
local log = require "prosody.util.logger".init("stats");
local timer = require "prosody.util.timer";
local fire_event = prosody.events.fire_event;
local array = require "prosody.util.array";
local timed = require "prosody.util.openmetrics".timed;

local stats_interval_config = config.get("*", "statistics_interval");
local stats_interval = tonumber(stats_interval_config);
if stats_interval_config and not stats_interval and stats_interval_config ~= "manual" then
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
if stats_interval_config == "manual" then
	stats_interval = nil;
end

local builtin_providers = {
	internal = "prosody.util.statistics";
	statsd = "prosody.util.statsd";
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

local measure, collect, metric, cork, uncork;

if stats then
	function metric(type_, name, unit, description, labels, extra)
		local registry = stats.metric_registry
		local f = assert(registry[type_], "unknown metric family type: "..type_);
		return f(registry, name, unit or "", description or "", labels, extra);
	end

	local function new_legacy_metric(stat_type, name, unit, description, fixed_label_key, fixed_label_value, extra)
		local label_keys = array()
		local conf = extra or {}
		if fixed_label_key then
			label_keys:push(fixed_label_key)
		end
		unit = unit or ""
		local mf = metric(stat_type, "prosody_" .. name, unit, description, label_keys, conf);
		if fixed_label_key then
			mf = mf:with_partial_label(fixed_label_value)
		end
		return mf:with_labels()
	end

	local function unwrap_legacy_extra(extra, type_, name, unit)
		local description = extra and extra.description or name.." "..type_
		unit = extra and extra.unit or unit
		return description, unit
	end

	-- These wrappers provide the pre-OpenMetrics interface of statsmanager
	-- and moduleapi (module:measure).
	local legacy_metric_wrappers = {
		amount = function(name, fixed_label_key, fixed_label_value, extra)
			local initial = 0
			if type(extra) == "number" then
				initial = extra
			else
				initial = extra and extra.initial or initial
			end
			local description, unit = unwrap_legacy_extra(extra, "amount", name)

			local m = new_legacy_metric("gauge", name, unit, description, fixed_label_key, fixed_label_value)
			m:set(initial or 0)
			return function(v)
				m:set(v)
			end
		end;

		counter = function(name, fixed_label_key, fixed_label_value, extra)
			if type(extra) == "number" then
				-- previous versions of the API allowed passing an initial
				-- value here; we do not allow that anymore, it is not a thing
				-- which makes sense with counters
				extra = nil
			end

			local description, unit = unwrap_legacy_extra(extra, "counter", name)

			local m = new_legacy_metric("counter", name, unit, description, fixed_label_key, fixed_label_value)
			m:set(0)
			return function(v)
				m:add(v)
			end
		end;

		rate = function(name, fixed_label_key, fixed_label_value, extra)
			if type(extra) == "number" then
				-- previous versions of the API allowed passing an initial
				-- value here; we do not allow that anymore, it is not a thing
				-- which makes sense with counters
				extra = nil
			end

			local description, unit = unwrap_legacy_extra(extra, "counter", name)

			local m = new_legacy_metric("counter", name, unit, description, fixed_label_key, fixed_label_value)
			m:set(0)
			return function()
				m:add(1)
			end
		end;

		times = function(name, fixed_label_key, fixed_label_value, extra)
			local conf = {}
			if extra and extra.buckets then
				conf.buckets = extra.buckets
			else
				conf.buckets = { 0.001, 0.01, 0.1, 1.0, 10.0, 100.0 }
			end
			local description, _ = unwrap_legacy_extra(extra, "times", name)

			local m = new_legacy_metric("histogram", name, "seconds", description, fixed_label_key, fixed_label_value, conf)
			return function()
				return timed(m)
			end
		end;

		sizes = function(name, fixed_label_key, fixed_label_value, extra)
			local conf = {}
			if extra and extra.buckets then
				conf.buckets = extra.buckets
			else
				conf.buckets = { 1024, 4096, 32768, 131072, 1048576, 4194304, 33554432, 134217728, 1073741824 }
			end
			local description, _ = unwrap_legacy_extra(extra, "sizes", name)

			local m = new_legacy_metric("histogram", name, "bytes", description, fixed_label_key, fixed_label_value, conf)
			return function(v)
				m:sample(v)
			end
		end;

		distribution = function(name, fixed_label_key, fixed_label_value, extra)
			if type(extra) == "string" then
				-- compat with previous API
				extra = { unit = extra }
			end
			local description, unit = unwrap_legacy_extra(extra, "distribution", name, "")
			local m = new_legacy_metric("summary", name, unit, description, fixed_label_key, fixed_label_value)
			return function(v)
				m:sample(v)
			end
		end;
	};

	-- Argument order switched here to support the legacy statsmanager.measure
	-- interface.
	function measure(stat_type, name, extra, fixed_label_key, fixed_label_value)
		local wrapper = assert(legacy_metric_wrappers[stat_type], "unknown legacy metric type "..stat_type)
		return wrapper(name, fixed_label_key, fixed_label_value, extra)
	end

	if stats.cork then
		function cork()
			return stats:cork()
		end

		function uncork()
			return stats:uncork()
		end
	else
		function cork() end
		function uncork() end
	end

	if stats_interval or stats_interval_config == "manual" then

		local mark_collection_start = measure("times", "stats.collection");
		local mark_processing_start = measure("times", "stats.processing");

		function collect()
			local mark_collection_done = mark_collection_start();
			fire_event("stats-update");
			-- ensure that the backend is uncorked, in case it got stuck at
			-- some point, to avoid infinite resource use
			uncork()
			mark_collection_done();
			local manual_result = nil

			if stats.metric_registry then
				-- only if supported by the backend, we fire the event which
				-- provides the current metric values
				local mark_processing_done = mark_processing_start();
				local metric_registry = stats.metric_registry;
				fire_event("openmetrics-updated", { metric_registry = metric_registry })
				mark_processing_done();
				manual_result = metric_registry;
			end

			return stats_interval, manual_result;
		end
		if stats_interval then
			log("debug", "Statistics enabled using %s provider, collecting every %d seconds", stats_provider_name, stats_interval);
			timer.add_task(stats_interval, collect);
			prosody.events.add_handler("server-started", function () collect() end, -1);
			prosody.events.add_handler("server-stopped", function () collect() end, -1);
		else
			log("debug", "Statistics enabled using %s provider, no scheduled collection", stats_provider_name);
		end
	else
		log("debug", "Statistics enabled using %s provider, collection is disabled", stats_provider_name);
	end
else
	log("debug", "Statistics disabled");
	function measure() return measure; end

	local dummy_mt = {}
	function dummy_mt.__newindex()
	end
	function dummy_mt:__index()
		return self
	end
	function dummy_mt:__call()
		return self
	end
	local dummy = {}
	setmetatable(dummy, dummy_mt)

	function metric() return dummy; end
	function cork() end
	function uncork() end
end

local exported_collect = nil;
if stats_interval_config == "manual" then
	exported_collect = collect;
end

return {
	collect = exported_collect;
	measure = measure;
	cork = cork;
	uncork = uncork;
	metric = metric;
	get_metric_registry = function ()
		return stats and stats.metric_registry or nil
	end;
};
