-- Because we deal with pre-authed sessions and streams we can't be host-specific
module:set_global();

local filters = require "prosody.util.filters";
local throttle = require "prosody.util.throttle";
local timer = require "prosody.util.timer";
local ceil = math.ceil;

local limits_cfg = module:get_option("limits", {});
local limits_resolution = module:get_option_number("limits_resolution", 1);

local default_bytes_per_second = 3000;
local default_burst = 2;

local rate_units = { b = 1, k = 3, m = 6, g = 9, t = 12 } -- Plan for the future.
local function parse_rate(rate, sess_type)
	local quantity, unit, exp;
	if rate then
		quantity, unit = rate:match("^(%d+) ?([^/]+)/s$");
		exp = quantity and rate_units[unit:sub(1,1):lower()];
	end
	if not exp then
		module:log("error", "Error parsing rate for %s: %q, using default rate (%d bytes/s)", sess_type, rate, default_bytes_per_second);
		return default_bytes_per_second;
	end
	return quantity*(10^exp);
end

local function parse_burst(burst, sess_type)
	if type(burst) == "string" then
		burst = burst:match("^(%d+) ?s$");
	end
	local n_burst = tonumber(burst);
	if burst and not n_burst then
		module:log("error", "Unable to parse burst for %s: %q, using default burst interval (%ds)", sess_type, burst, default_burst);
	end
	return n_burst or default_burst;
end

-- Process config option into limits table:
-- limits = { c2s = { bytes_per_second = X, burst_seconds = Y } }
local limits = {
	c2s = {
		bytes_per_second = 10 * 1024;
		burst_seconds = 2;
	};
	s2sin = {
		bytes_per_second = 30 * 1024;
		burst_seconds = 2;
	};
};

for sess_type, sess_limits in pairs(limits_cfg) do
	limits[sess_type] = {
		bytes_per_second = parse_rate(sess_limits.rate, sess_type);
		burst_seconds = parse_burst(sess_limits.burst, sess_type);
	};
end

local default_filter_set = {};

function default_filter_set.bytes_in(bytes, session)
	local sess_throttle = session.throttle;
	if sess_throttle then
		local ok, _, outstanding = sess_throttle:poll(#bytes, true);
		if not ok then
			session.log("debug", "Session over rate limit (%d) with %d (by %d), pausing", sess_throttle.max, #bytes, outstanding);
			outstanding = ceil(outstanding);
			session.conn:pause(); -- Read no more data from the connection until there is no outstanding data
			local outstanding_data = bytes:sub(-outstanding);
			bytes = bytes:sub(1, #bytes-outstanding);
			timer.add_task(limits_resolution, function ()
				if not session.conn then return; end
				if sess_throttle:peek(#outstanding_data) then
					session.log("debug", "Resuming paused session");
					session.conn:resume();
				end
				-- Handle what we can of the outstanding data
				session.data(outstanding_data);
			end);
		end
	end
	return bytes;
end

local type_filters = {
	c2s = default_filter_set;
	s2sin = default_filter_set;
	s2sout = default_filter_set;
};

local function filter_hook(session)
	local session_type = session.type:match("^[^_]+");
	local filter_set, opts = type_filters[session_type], limits[session_type];
	if opts then
		if session.conn and session.conn.setlimit then
			session.conn:setlimit(opts.bytes_per_second);
			-- Currently no burst support
		else
			session.throttle = throttle.create(opts.bytes_per_second * opts.burst_seconds, opts.burst_seconds);
			filters.add_filter(session, "bytes/in", filter_set.bytes_in, 1000);
		end
	end
end

function module.load()
	filters.add_filter_hook(filter_hook);
end

function module.unload()
	filters.remove_filter_hook(filter_hook);
end

function unlimited(session)
	local session_type = session.type:match("^[^_]+");
	if session.conn and session.conn.setlimit then
		session.conn:setlimit(0);
		-- Currently no burst support
	else
		local filter_set = type_filters[session_type];
		filters.remove_filter(session, "bytes/in", filter_set.bytes_in);
		session.throttle = nil;
	end
end

function module.add_host(module)
	local unlimited_jids = module:get_option_inherited_set("unlimited_jids", {});

	if not unlimited_jids:empty() then
		module:hook("authentication-success", function (event)
			local session = event.session;
			local jid = session.username .. "@" .. session.host;
			if unlimited_jids:contains(jid) then
				unlimited(session);
			end
		end);

		module:hook("s2sout-established", function (event)
			local session = event.session;
			if unlimited_jids:contains(session.to_host) then
				unlimited(session);
			end
		end);

		module:hook("s2sin-established", function (event)
			local session = event.session;
			if session.from_host and unlimited_jids:contains(session.from_host) then
				unlimited(session);
			end
		end);

	end
end
