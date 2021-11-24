-- Export statistics in OpenMetrics format
--
-- Copyright (C) 2014 Daurnimator
-- Copyright (C) 2018 Emmanuel Gil Peyrot <linkmauve@linkmauve.fr>
-- Copyright (C) 2021 Jonas Schäfer <jonas@zombofant.net>
--
-- This module is MIT/X11 licensed.

module:set_global();

local statsman = require "core.statsmanager";
local ip = require "util.ip";

local get_metric_registry = statsman.get_metric_registry;
local collect = statsman.collect;

local get_metrics;

local permitted_ips = module:get_option_set("openmetrics_allow_ips", { "::1", "127.0.0.1" });
local permitted_cidr = module:get_option_string("openmetrics_allow_cidr");

local function is_permitted(request)
	local ip_raw = request.ip;
	if permitted_ips:contains(ip_raw) or
	   (permitted_cidr and ip.match(ip.new_ip(ip_raw), ip.parse_cidr(permitted_cidr))) then
		return true;
	end
	return false;
end

function get_metrics(event)
	if not is_permitted(event.request) then
		return 403; -- Forbidden
	end

	local response = event.response;
	response.headers.content_type = "application/openmetrics-text; version=0.0.4";

	if collect then
		-- Ensure to get up-to-date samples when running in manual mode
		collect()
	end

	local registry = get_metric_registry()
	if registry == nil then
		response.headers.content_type = "text/plain; charset=utf-8"
		response.status_code = 404
		return "No statistics provider configured\n"
	end

	return registry:render();
end

function module.add_host(module)
	module:depends "http";
	module:provides("http", {
		default_path = "metrics";
		route = {
			GET = get_metrics;
		};
	});
end
