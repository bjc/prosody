-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- luacheck: ignore 212

local new_sasl = require "util.sasl".new;
local datamanager = require "util.datamanager";
local hosts = prosody.hosts;

-- define auth provider
local provider = {};

function provider.test_password(username, password)
	return nil, "Password based auth not supported.";
end

function provider.get_password(username)
	return nil, "Password not available.";
end

function provider.set_password(username, password)
	return nil, "Password based auth not supported.";
end

function provider.user_exists(username)
	return nil, "Only anonymous users are supported."; -- FIXME check if anonymous user is connected?
end

function provider.create_user(username, password)
	return nil, "Account creation/modification not supported.";
end

function provider.get_sasl_handler()
	local anonymous_authentication_profile = {
		anonymous = function(sasl, username, realm)
			return true; -- for normal usage you should always return true here
		end
	};
	return new_sasl(module.host, anonymous_authentication_profile);
end

function provider.users()
	return next, hosts[module.host].sessions, nil;
end

-- datamanager callback to disable writes
local function dm_callback(username, host, datastore, data)
	if host == module.host then
		return false;
	end
	return username, host, datastore, data;
end

if not module:get_option_boolean("allow_anonymous_s2s", false) then
	module:hook("route/remote", function (event)
		return false; -- Block outgoing s2s from anonymous users
	end, 300);
end

function module.load()
	datamanager.add_callback(dm_callback);
end
function module.unload()
	datamanager.remove_callback(dm_callback);
end

module:provides("auth", provider);

