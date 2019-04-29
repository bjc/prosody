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
	skeletons:set(skeleton(user.username), { username = user.username });
end);

module:hook("user-deleted", function(user)
	skeletons:set(skeleton(user.username), nil);
end);

module:hook("user-registering", function(user)
	if skeletons:get(skeleton(user.username)) then
		user.allowed = false;
	end
end);

function module.command(arg)
	if (arg[1] ~= "bootstrap" or not arg[2]) then
		usage("mod_mimicking bootstrap <host>", "Initialize username mimicry index");
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

	for user in usermanager.users(host) do
		skeletons:set(skeleton(user), { username = user });
	end
end
