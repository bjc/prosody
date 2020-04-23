-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local create_throttle = require "util.throttle".create;
local new_cache = require "util.cache".new;
local ip_util = require "util.ip";
local new_ip = ip_util.new_ip;
local match_ip = ip_util.match;
local parse_cidr = ip_util.parse_cidr;
local errors = require "util.error";

local min_seconds_between_registrations = module:get_option_number("min_seconds_between_registrations");
local whitelist_only = module:get_option_boolean("whitelist_registration_only");
local whitelisted_ips = module:get_option_set("registration_whitelist", { "127.0.0.1", "::1" })._items;
local blacklisted_ips = module:get_option_set("registration_blacklist", {})._items;

local throttle_max = module:get_option_number("registration_throttle_max", min_seconds_between_registrations and 1);
local throttle_period = module:get_option_number("registration_throttle_period", min_seconds_between_registrations);
local throttle_cache_size = module:get_option_number("registration_throttle_cache_size", 100);
local blacklist_overflow = module:get_option_boolean("blacklist_on_registration_throttle_overload", false);

local throttle_cache = new_cache(throttle_cache_size, blacklist_overflow and function (ip, throttle)
	if not throttle:peek() then
		module:log("info", "Adding ip %s to registration blacklist", ip);
		blacklisted_ips[ip] = true;
	end
end or nil);

local function check_throttle(ip)
	if not throttle_max then return true end
	local throttle = throttle_cache:get(ip);
	if not throttle then
		throttle = create_throttle(throttle_max, throttle_period);
	end
	throttle_cache:set(ip, throttle);
	return throttle:poll(1);
end

local function ip_in_set(set, ip)
	if set[ip] then
		return true;
	end
	ip = new_ip(ip);
	for in_set in pairs(set) do
		if match_ip(ip, parse_cidr(in_set)) then
			return true;
		end
	end
	return false;
end

local err_registry = {
	blacklisted = {
		text = "Your IP address is blacklisted";
		type = "auth";
		condition = "forbidden";
	};
	not_whitelisted = {
		text = "Your IP address is not whitelisted";
		type = "auth";
		condition = "forbidden";
	};
	throttled = {
		text = "Too many registrations from this IP address recently";
		type = "wait";
		condition = "policy-violation";
	};
}

module:hook("user-registering", function (event)
	local session = event.session;
	local ip = event.ip or session and session.ip;
	local log = session and session.log or module._log;
	if not ip then
		log("warn", "IP not known; can't apply blacklist/whitelist");
	elseif ip_in_set(blacklisted_ips, ip) then
		log("debug", "Registration disallowed by blacklist");
		event.allowed = false;
		event.error = errors.new("blacklisted", event, err_registry);
	elseif (whitelist_only and not ip_in_set(whitelisted_ips, ip)) then
		log("debug", "Registration disallowed by whitelist");
		event.allowed = false;
		event.error = errors.new("not_whitelisted", event, err_registry);
	elseif throttle_max and not ip_in_set(whitelisted_ips, ip) then
		if not check_throttle(ip) then
			log("debug", "Registrations over limit for ip %s", ip or "?");
			event.allowed = false;
			event.error = errors.new("throttled", event, err_registry);
		end
	end
	if event.error then
		-- COMPAT pre-util.error
		event.reason = event.error.text;
		event.error_type = event.error.type;
		event.error_condition = event.error.condition;
	end
end);
