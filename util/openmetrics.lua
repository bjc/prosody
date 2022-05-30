--[[
This module implements a subset of the OpenMetrics Internet Draft version 00.

URL: https://tools.ietf.org/html/draft-richih-opsawg-openmetrics-00

The following metric types are supported:

- Counter
- Gauge
- Histogram
- Summary

It is used by util.statsd and util.statistics to provide the OpenMetrics API.

To understand what this module is about, it is useful to familiarize oneself
with the terms MetricFamily, Metric, LabelSet, Label and MetricPoint as
defined in the I-D linked above.
--]]
-- metric constructor interface:
-- metric_ctor(..., family_name, labels, extra)

local time = require "util.time".now;
local select = select;
local array = require "util.array";
local log = require "util.logger".init("util.openmetrics");
local new_multitable = require "util.multitable".new;
local iter_multitable = require "util.multitable".iter;
local t_concat, t_insert = table.concat, table.insert;
local t_pack, t_unpack = require "util.table".pack, table.unpack or unpack; --luacheck: ignore 113/unpack

-- BEGIN of Utility: "metric proxy"
-- This allows to wrap a MetricFamily in a proxy which only provides the
-- `with_labels` and `with_partial_label` methods. This allows to pre-set one
-- or more labels on a metric family. This is used in particular via
-- `with_partial_label` by the moduleapi in order to pre-set the `host` label
-- on metrics created in non-global modules.
local metric_proxy_mt = {}
metric_proxy_mt.__name = "metric_proxy"
metric_proxy_mt.__index = metric_proxy_mt

local function new_metric_proxy(metric_family, with_labels_proxy_fun)
	return setmetatable({
		_family = metric_family,
		with_labels = function(self, ...)
			return with_labels_proxy_fun(self._family, ...)
		end;
		with_partial_label = function(self, label)
			return new_metric_proxy(self._family, function(family, ...)
				return family:with_labels(label, ...)
			end)
		end
	}, metric_proxy_mt);
end

-- END of Utility: "metric proxy"

-- BEGIN Rendering helper functions (internal)

local function escape(text)
	return text:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n");
end

local function escape_name(name)
	return name:gsub("/", "__"):gsub("[^A-Za-z0-9_]", "_"):gsub("^[^A-Za-z_]", "_%1");
end

local function repr_help(metric, docstring)
	docstring = docstring:gsub("\\", "\\\\"):gsub("\n", "\\n");
	return "# HELP "..escape_name(metric).." "..docstring.."\n";
end

local function repr_unit(metric, unit)
	if not unit then
		unit = ""
	else
		unit = unit:gsub("\\", "\\\\"):gsub("\n", "\\n");
	end
	return "# UNIT "..escape_name(metric).." "..unit.."\n";
end

-- local allowed_types = { counter = true, gauge = true, histogram = true, summary = true, untyped = true };
-- local allowed_types = { "counter", "gauge", "histogram", "summary", "untyped" };
local function repr_type(metric, type_)
	-- if not allowed_types:contains(type_) then
	-- 	return;
	-- end
	return "# TYPE "..escape_name(metric).." "..type_.."\n";
end

local function repr_label(key, value)
	return key.."=\""..escape(value).."\"";
end

local function repr_labels(labelkeys, labelvalues, extra_labels)
	local values = {}
	if labelkeys then
		for i, key in ipairs(labelkeys) do
			local value = labelvalues[i]
			t_insert(values, repr_label(escape_name(key), escape(value)));
		end
	end
	if extra_labels then
		for key, value in pairs(extra_labels) do
			t_insert(values, repr_label(escape_name(key), escape(value)));
		end
	end
	if #values == 0 then
		return "";
	end
	return "{"..t_concat(values, ",").."}";
end

local function repr_sample(metric, labelkeys, labelvalues, extra_labels, value)
	return escape_name(metric)..repr_labels(labelkeys, labelvalues, extra_labels).." "..string.format("%.17g", value).."\n";
end

-- END Rendering helper functions (internal)

local function render_histogram_le(v)
	if v == 1/0 then
		-- I-D-00: 4.1.2.2.1:
		--    Exposers MUST produce output for positive infinity as +Inf.
		return "+Inf"
	end

	return string.format("%.14g", v)
end

-- BEGIN of generic MetricFamily implementation

local metric_family_mt = {}
metric_family_mt.__name = "metric_family"
metric_family_mt.__index = metric_family_mt

local function histogram_metric_ctor(orig_ctor, buckets)
	return function(family_name, labels, extra)
		return orig_ctor(buckets, family_name, labels, extra)
	end
end

local function new_metric_family(backend, type_, family_name, unit, description, label_keys, extra)
	local metric_ctor = assert(backend[type_], "statistics backend does not support "..type_.." metrics families")
	local labels = label_keys or {}
	local user_labels = #labels
	if type_ == "histogram" then
		local buckets = extra and extra.buckets
		if not buckets then
			error("no buckets given for histogram metric")
		end
		buckets = array(buckets)
		buckets:push(1/0)  -- must have +inf bucket

		metric_ctor = histogram_metric_ctor(metric_ctor, buckets)
	end

	local data
	if #labels == 0 then
		data = metric_ctor(family_name, nil, extra)
	else
		data = new_multitable()
	end

	local mf = {
		family_name = family_name,
		data = data,
		type_ = type_,
		unit = unit,
		description = description,
		user_labels = user_labels,
		label_keys = labels,
		extra = extra,
		_metric_ctor = metric_ctor,
	}
	setmetatable(mf, metric_family_mt);
	return mf
end

function metric_family_mt:new_metric(labels)
	return self._metric_ctor(self.family_name, labels, self.extra)
end

function metric_family_mt:clear()
	for _, metric in self:iter_metrics() do
		metric:reset()
	end
end

function metric_family_mt:with_labels(...)
	local count = select('#', ...)
	if count ~= self.user_labels then
		error("number of labels passed to with_labels does not match number of label keys")
	end
	if count == 0 then
		return self.data
	end
	local metric = self.data:get(...)
	if not metric then
		local values = t_pack(...)
		metric = self:new_metric(values)
		values[values.n+1] = metric
		self.data:set(t_unpack(values, 1, values.n+1))
	end
	return metric
end

function metric_family_mt:with_partial_label(label)
	return new_metric_proxy(self, function (family, ...)
		return family:with_labels(label, ...)
	end)
end

function metric_family_mt:iter_metrics()
	if #self.label_keys == 0 then
		local done = false
		return function()
			if done then
				return nil
			end
			done = true
			return {}, self.data
		end
	end
	local searchkeys = {};
	local nlabels = #self.label_keys
	for i=1,nlabels do
		searchkeys[i] = nil;
	end
	local it, state = iter_multitable(self.data, t_unpack(searchkeys, 1, nlabels))
	return function(_s)
		local label_values = t_pack(it(_s))
		if label_values.n == 0 then
			return nil, nil
		end
		local metric = label_values[label_values.n]
		label_values[label_values.n] = nil
		label_values.n = label_values.n - 1
		return label_values, metric
	end, state
end

-- END of generic MetricFamily implementation

-- BEGIN of MetricRegistry implementation


-- Helper to test whether two metrics are "equal".
local function equal_metric_family(mf1, mf2)
	if mf1.type_ ~= mf2.type_ then
		return false
	end
	if #mf1.label_keys ~= #mf2.label_keys then
		return false
	end
	-- Ignoring unit here because in general it'll be part of the name anyway
	-- So either the unit was moved into/out of the name (which is a valid)
	-- thing to do on an upgrade or we would expect not to see any conflicts
	-- anyway.
	--[[
	if mf1.unit ~= mf2.unit then
		return false
	end
	]]
	for i, key in ipairs(mf1.label_keys) do
		if key ~= mf2.label_keys[i] then
			return false
		end
	end
	return true
end

-- If the unit is not empty, add it to the full name as per the I-D spec.
local function compose_name(name, unit)
	local full_name = name
	if unit and unit ~= "" then
		full_name = full_name .. "_" .. unit
	end
	-- TODO: prohibit certain suffixes used by metrics if where they may cause
	-- conflicts
	return full_name
end

local metric_registry_mt = {}
metric_registry_mt.__name = "metric_registry"
metric_registry_mt.__index = metric_registry_mt

local function new_metric_registry(backend)
	local reg = {
		families = {},
		backend = backend,
	}
	setmetatable(reg, metric_registry_mt)
	return reg
end

function metric_registry_mt:register_metric_family(name, metric_family)
	local existing = self.families[name];
	if existing then
		if not equal_metric_family(metric_family, existing) then
			-- We could either be strict about this, or replace the
			-- existing metric family with the new one.
			-- Being strict is nice to avoid programming errors /
			-- conflicts, but causes issues when a new version of a module
			-- is loaded.
			--
			-- We will thus assume that the new metric is the correct one;
			-- That is probably OK because unless you're reaching down into
			-- the util.openmetrics or core.statsmanager API, your metric
			-- name is going to be scoped to `prosody_mod_$modulename`
			-- anyway and the damage is thus controlled.
			--
			-- To make debugging such issues easier, we still log.
			log("debug", "replacing incompatible existing metric family %s", name)
			-- Below is the code to be strict.
			--error("conflicting declarations for metric family "..name)
		else
			return existing
		end
	end
	self.families[name] = metric_family
	return metric_family
end

function metric_registry_mt:gauge(name, unit, description, labels, extra)
	name = compose_name(name, unit)
	local mf = new_metric_family(self.backend, "gauge", name, unit, description, labels, extra)
	mf = self:register_metric_family(name, mf)
	return mf
end

function metric_registry_mt:counter(name, unit, description, labels, extra)
	name = compose_name(name, unit)
	local mf = new_metric_family(self.backend, "counter", name, unit, description, labels, extra)
	mf = self:register_metric_family(name, mf)
	return mf
end

function metric_registry_mt:histogram(name, unit, description, labels, extra)
	name = compose_name(name, unit)
	local mf = new_metric_family(self.backend, "histogram", name, unit, description, labels, extra)
	mf = self:register_metric_family(name, mf)
	return mf
end

function metric_registry_mt:summary(name, unit, description, labels, extra)
	name = compose_name(name, unit)
	local mf = new_metric_family(self.backend, "summary", name, unit, description, labels, extra)
	mf = self:register_metric_family(name, mf)
	return mf
end

function metric_registry_mt:get_metric_families()
	return self.families
end

function metric_registry_mt:render()
	local answer = {};
	for metric_family_name, metric_family in pairs(self:get_metric_families()) do
		t_insert(answer, repr_help(metric_family_name, metric_family.description))
		t_insert(answer, repr_unit(metric_family_name, metric_family.unit))
		t_insert(answer, repr_type(metric_family_name, metric_family.type_))
		for labelset, metric in metric_family:iter_metrics() do
			for suffix, extra_labels, value in metric:iter_samples() do
				t_insert(answer, repr_sample(metric_family_name..suffix, metric_family.label_keys, labelset, extra_labels, value))
			end
		end
	end
	t_insert(answer, "# EOF\n")
	return t_concat(answer, "");
end

-- END of MetricRegistry implementation

-- BEGIN of general helpers for implementing high-level APIs on top of OpenMetrics

local function timed(metric)
	local t0 = time()
	local submitter = assert(metric.sample or metric.set, "metric type cannot be used with timed()")
	return function()
		local t1 = time()
		submitter(metric, t1-t0)
	end
end

-- END of general helpers

return {
	new_metric_proxy = new_metric_proxy;
	new_metric_registry = new_metric_registry;
	render_histogram_le = render_histogram_le;
	timed = timed;
}
