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
local warn = require "util.prosodyctl".show_warning;
local users = require "usermanager".users;

local skeletons = module:open_store("skeletons");

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
		usage("mod_mimicking bootstrap <host>", "Initialize skeleton database");
		return;
	end

	local host = arg[2];

	local host_session = prosody.hosts[host];
	if not host_session then
		return "No such host";
	end
	local provider = host_session.users;
	if not(provider) or provider.name == "null" then
		usermanager.initialize_host(host);
	end
	storagemanager.initialize_host(host);

	for user in users(host) do
		datamanager.store(skeleton(user), host, "skeletons", {username = user});
	end
end
