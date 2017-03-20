local socket = require "socket";

local time = require "util.time".now

local function new(config)
	if not config or not config.statsd_server then
		return nil, "No statsd server specified in the config, please see https://prosody.im/doc/statistics";
	end

	local sock = socket.udp();
	sock:setpeername(config.statsd_server, config.statsd_port or 8125);

	local prefix = (config.prefix or "prosody")..".";

	local function send_metric(s)
		return sock:send(prefix..s);
	end

	local function send_gauge(name, amount, relative)
		local s_amount = tostring(amount);
		if relative and amount > 0 then
			s_amount = "+"..s_amount;
		end
		return send_metric(name..":"..s_amount.."|g");
	end

	local function send_counter(name, amount)
		return send_metric(name..":"..tostring(amount).."|c");
	end

	local function send_duration(name, duration)
		return send_metric(name..":"..tostring(duration).."|ms");
	end

	local function send_histogram_sample(name, sample)
		return send_metric(name..":"..tostring(sample).."|h");
	end

	local methods;
	methods = {
		amount = function (name, initial)
			if initial then
				send_gauge(name, initial);
			end
			return function (new_v) send_gauge(name, new_v); end
		end;
		counter = function (name, initial) --luacheck: ignore 212/initial
			return function (delta)
				send_gauge(name, delta, true);
			end;
		end;
		rate = function (name)
			return function ()
				send_counter(name, 1);
			end;
		end;
		distribution = function (name, unit, type) --luacheck: ignore 212/unit 212/type
			return function (value)
				send_histogram_sample(name, value);
			end;
		end;
		sizes = function (name)
			name = name.."_size";
			return function (value)
				send_histogram_sample(name, value);
			end;
		end;
		times = function (name)
			return function ()
				local start_time = time();
				return function ()
					local end_time = time();
					local duration = end_time - start_time;
					send_duration(name, duration*1000);
				end
			end;
		end;
	};
	return methods;
end

return {
	new = new;
}
