-- Prosody IM
-- Copyright (C) 2012 Florian Zeitz
-- Copyright (C) 2019 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local encodings = require "util.encodings";
assert(encodings.confusable, "This module requires that Prosody be built with ICU");
local skeleton = encodings.confusable.skeleton;

local usage = require "util.prosodyctl".show_usage;
local usermanager = require "core.usermanager";
local storagemanager = require "core.storagemanager";

local skeletons
function module.load()
	if module.host ~= "*" then
		skeletons = module:open_store("skeletons");
	end
end

module:hook("user-registered", function(user)
	local skel = skeleton(user.username);
	local ok, err = skeletons:set(skel, { username = user.username });
	if not ok then
		module:log("error", "Unable to store mimicry data (%q => %q): %s", user.username, skel, err);
	end
end);

module:hook("user-deleted", function(user)
	local skel = skeleton(user.username);
	local ok, err = skeletons:set(skel, nil);
	if not ok and err then
		module:log("error", "Unable to clear mimicry data (%q): %s", skel, err);
	end
end);

module:hook("user-registering", function(user)
	local existing, err = skeletons:get(skeleton(user.username));
	if existing then
		module:log("debug", "Attempt to register username '%s' which could be confused with '%s'", user.username, existing.username);
		user.allowed = false;
	elseif err then
		module:log("error", "Unable to check if new username '%s' can be confused with any existing user: %s", err);
	end
end);

function module.command(arg)
	if (arg[1] ~= "bootstrap" or not arg[2]) then
		usage("mod_mimicking bootstrap <host>", "Initialize username mimicry database");
		return;
	end

	local host = arg[2];

	local host_session = prosody.hosts[host];
	if not host_session then
		return "No such host";
	end

	storagemanager.initialize_host(host);
	usermanager.initialize_host(host);

	skeletons = storagemanager.open(host, "skeletons");

	local count = 0;
	for user in usermanager.users(host) do
		local skel = skeleton(user);
		local existing, err = skeletons:get(skel);
		if existing and existing.username ~= user then
			module:log("warn", "Existing usernames '%s' and '%s' are confusable", existing.username, user);
		elseif err then
			module:log("error", "Error checking for existing mimicry data (%q = %q): %s", user, skel, err);
		end
		local ok, err = skeletons:set(skel, { username = user });
		if ok then
			count = count + 1;
		elseif err then
			module:log("error", "Unable to store mimicry data (%q => %q): %s", user, skel, err);
		end
	end
	module:log("info", "%d usernames indexed", count);
end
