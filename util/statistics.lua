local time = require "util.time".now;
local new_metric_registry = require "util.openmetrics".new_metric_registry;
local render_histogram_le = require "util.openmetrics".render_histogram_le;

-- BEGIN of Metric implementations

-- Gauges
local gauge_metric_mt = {}
gauge_metric_mt.__index = gauge_metric_mt

local function new_gauge_metric()
	local metric = { value = 0 }
	setmetatable(metric, gauge_metric_mt)
	return metric
end

function gauge_metric_mt:set(value)
	self.value = value
end

function gauge_metric_mt:add(delta)
	self.value = self.value + delta
end

function gauge_metric_mt:reset()
	self.value = 0
end

function gauge_metric_mt:iter_samples()
	local done = false
	return function(_s)
		if done then
			return nil, true
		end
		done = true
		return "", nil, _s.value
	end, self
end

-- Counters
local counter_metric_mt = {}
counter_metric_mt.__index = counter_metric_mt

local function new_counter_metric()
	local metric = {
		_created = time(),
		value = 0,
	}
	setmetatable(metric, counter_metric_mt)
	return metric
end

function counter_metric_mt:set(value)
	self.value = value
end

function counter_metric_mt:add(value)
	self.value = (self.value or 0) + value
end

function counter_metric_mt:iter_samples()
	local step = 0
	return function(_s)
		step = step + 1
		if step == 1 then
			return "_created", nil, _s._created
		elseif step == 2 then
			return "_total", nil, _s.value
		else
			return nil, nil, true
		end
	end, self
end

function counter_metric_mt:reset()
	self.value = 0
end

-- Histograms
local histogram_metric_mt = {}
histogram_metric_mt.__index = histogram_metric_mt

local function new_histogram_metric(buckets)
	local metric = {
		_created = time(),
		_sum = 0,
		_count = 0,
	}
	-- the order of buckets matters unfortunately, so we cannot directly use
	-- the thresholds as table keys
	for i, threshold in ipairs(buckets) do
		metric[i] = {
			threshold = threshold,
			threshold_s = render_histogram_le(threshold),
			count = 0
		}
	end
	setmetatable(metric, histogram_metric_mt)
	return metric
end

function histogram_metric_mt:sample(value)
	-- According to the I-D, values must be part of all buckets
	for i, bucket in pairs(self) do
		if "number" == type(i) and value <= bucket.threshold then
			bucket.count = bucket.count + 1
		end
	end
	self._sum = self._sum + value
	self._count = self._count + 1
end

function histogram_metric_mt:iter_samples()
	local key = nil
	return function (_s)
		local data
		key, data = next(_s, key)
		if key == "_created" or key == "_sum" or key == "_count" then
			return key, nil, data
		elseif key ~= nil then
			return "_bucket", {["le"] = data.threshold_s}, data.count
		else
			return nil, nil, nil
		end
	end, self
end

function histogram_metric_mt:reset()
	self._created = time()
	self._count = 0
	self._sum = 0
	for i, bucket in pairs(self) do
		if "number" == type(i) then
			bucket.count = 0
		end
	end
end

-- Summary
local summary_metric_mt = {}
summary_metric_mt.__index = summary_metric_mt

local function new_summary_metric()
	-- quantiles are not supported yet
	local metric = {
		_created = time(),
		_sum = 0,
		_count = 0,
	}
	setmetatable(metric, summary_metric_mt)
	return metric
end

function summary_metric_mt:sample(value)
	self._sum = self._sum + value
	self._count = self._count + 1
end

function summary_metric_mt:iter_samples()
	local key = nil
	return function (_s)
		local data
		key, data = next(_s, key)
		return key, nil, data
	end, self
end

function summary_metric_mt:reset()
	self._created = time()
	self._count = 0
	self._sum = 0
end

local pull_backend = {
	gauge = new_gauge_metric,
	counter = new_counter_metric,
	histogram = new_histogram_metric,
	summary = new_summary_metric,
}

-- END of Metric implementations

local function new()
	return {
		metric_registry = new_metric_registry(pull_backend),
	}
end

return {
	new = new;
}
