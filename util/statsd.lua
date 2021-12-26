local socket = require "socket";
local time = require "util.time".now;
local array = require "util.array";
local t_concat = table.concat;

local new_metric_registry = require "util.openmetrics".new_metric_registry;
local render_histogram_le = require "util.openmetrics".render_histogram_le;

-- BEGIN of Metric implementations

-- Gauges
local gauge_metric_mt = {}
gauge_metric_mt.__index = gauge_metric_mt

local function new_gauge_metric(full_name, impl)
	local metric = {
		_full_name = full_name;
		_impl = impl;
		value = 0;
	}
	setmetatable(metric, gauge_metric_mt)
	return metric
end

function gauge_metric_mt:set(value)
	self.value = value
	self._impl:push_gauge(self._full_name, value)
end

function gauge_metric_mt:add(delta)
	self.value = self.value + delta
	self._impl:push_gauge(self._full_name, self.value)
end

function gauge_metric_mt:reset()
	self.value = 0
	self._impl:push_gauge(self._full_name, 0)
end

function gauge_metric_mt.iter_samples()
	-- statsd backend does not support iteration.
	return function()
		return nil
	end
end

-- Counters
local counter_metric_mt = {}
counter_metric_mt.__index = counter_metric_mt

local function new_counter_metric(full_name, impl)
	local metric = {
		_full_name = full_name,
		_impl = impl,
		value = 0,
	}
	setmetatable(metric, counter_metric_mt)
	return metric
end

function counter_metric_mt:set(value)
	local delta = value - self.value
	self.value = value
	self._impl:push_counter_delta(self._full_name, delta)
end

function counter_metric_mt:add(value)
	self.value = (self.value or 0) + value
	self._impl:push_counter_delta(self._full_name, value)
end

function counter_metric_mt.iter_samples()
	-- statsd backend does not support iteration.
	return function()
		return nil
	end
end

function counter_metric_mt:reset()
	self.value = 0
end

-- Histograms
local histogram_metric_mt = {}
histogram_metric_mt.__index = histogram_metric_mt

local function new_histogram_metric(buckets, full_name, impl)
	-- NOTE: even though the more or less proprietrary dogstatsd has its own
	-- histogram implementation, we push the individual buckets in this statsd
	-- backend for both consistency and compatibility across statsd
	-- implementations.
	local metric = {
		_sum_name = full_name..".sum",
		_count_name = full_name..".count",
		_impl = impl,
		_created = time(),
		_sum = 0,
		_count = 0,
	}
	-- the order of buckets matters unfortunately, so we cannot directly use
	-- the thresholds as table keys
	for i, threshold in ipairs(buckets) do
		local threshold_s = render_histogram_le(threshold)
		metric[i] = {
			threshold = threshold,
			threshold_s = threshold_s,
			count = 0,
			_full_name = full_name..".bucket."..(threshold_s:gsub("%.", "_")),
		}
	end
	setmetatable(metric, histogram_metric_mt)
	return metric
end

function histogram_metric_mt:sample(value)
	-- According to the I-D, values must be part of all buckets
	for i, bucket in pairs(self) do
		if "number" == type(i) and bucket.threshold >= value then
			bucket.count = bucket.count + 1
			self._impl:push_counter_delta(bucket._full_name, 1)
		end
	end
	self._sum = self._sum + value
	self._count = self._count + 1
	self._impl:push_gauge(self._sum_name, self._sum)
	self._impl:push_counter_delta(self._count_name, 1)
end

function histogram_metric_mt.iter_samples()
	-- statsd backend does not support iteration.
	return function()
		return nil
	end
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
	self._impl:push_gauge(self._sum_name, self._sum)
end

-- Summaries
local summary_metric_mt = {}
summary_metric_mt.__index = summary_metric_mt

local function new_summary_metric(full_name, impl)
	local metric = {
		_sum_name = full_name..".sum",
		_count_name = full_name..".count",
		_impl = impl,
	}
	setmetatable(metric, summary_metric_mt)
	return metric
end

function summary_metric_mt:sample(value)
	self._impl:push_counter_delta(self._sum_name, value)
	self._impl:push_counter_delta(self._count_name, 1)
end

function summary_metric_mt.iter_samples()
	-- statsd backend does not support iteration.
	return function()
		return nil
	end
end

function summary_metric_mt.reset()
end

-- BEGIN of statsd client implementation

local statsd_mt = {}
statsd_mt.__index = statsd_mt

function statsd_mt:cork()
	self.corked = true
	self.cork_buffer = self.cork_buffer or {}
end

function statsd_mt:uncork()
	self.corked = false
	self:_flush_cork_buffer()
end

function statsd_mt:_flush_cork_buffer()
	local buffer = self.cork_buffer
	for metric_name, value in pairs(buffer) do
		self:_send_gauge(metric_name, value)
		buffer[metric_name] = nil
	end
end

function statsd_mt:push_gauge(metric_name, value)
	if self.corked then
		self.cork_buffer[metric_name] = value
	else
		self:_send_gauge(metric_name, value)
	end
end

function statsd_mt:_send_gauge(metric_name, value)
	self:_send(self.prefix..metric_name..":"..tostring(value).."|g")
end

function statsd_mt:push_counter_delta(metric_name, delta)
	self:_send(self.prefix..metric_name..":"..tostring(delta).."|c")
end

function statsd_mt:_send(s)
	return self.sock:send(s)
end

-- END of statsd client implementation

local function build_metric_name(family_name, labels)
	local parts = array { family_name }
	if labels then
		parts:append(labels)
	end
	return t_concat(parts, "/"):gsub("%.", "_"):gsub("/", ".")
end

local function new(config)
	if not config or not config.statsd_server then
		return nil, "No statsd server specified in the config, please see https://prosody.im/doc/statistics";
	end

	local sock = socket.udp();
	sock:setpeername(config.statsd_server, config.statsd_port or 8125);

	local prefix = (config.prefix or "prosody")..".";

	local impl = {
		metric_registry = nil;
		sock = sock;
		prefix = prefix;
	};
	setmetatable(impl, statsd_mt)

	local backend = {
		gauge = function(family_name, labels)
			return new_gauge_metric(build_metric_name(family_name, labels), impl)
		end;
		counter = function(family_name, labels)
			return new_counter_metric(build_metric_name(family_name, labels), impl)
		end;
		histogram = function(buckets, family_name, labels)
			return new_histogram_metric(buckets, build_metric_name(family_name, labels), impl)
		end;
		summary = function(family_name, labels, extra)
			return new_summary_metric(build_metric_name(family_name, labels), impl, extra)
		end;
	};

	impl.metric_registry = new_metric_registry(backend);

	return impl;
end

return {
	new = new;
}
