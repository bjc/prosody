-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local log = require "util.logger".init("auth_anonymous");
local new_sasl = require "util.sasl".new;
local datamanager = require "util.datamanager";

function new_default_provider(host)
	local provider = { name = "anonymous" };

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

	return provider;
end

local function dm_callback(username, host, datastore, data)
	if host == module.host then
		return false;
	end
	return username, host, datastore, data;
end
local host = hosts[module.host];
local _saved_disallow_s2s = host.disallow_s2s;
function module.load()
	_saved_disallow_s2s = host.disallow_s2s;
	host.disallow_s2s = module:get_option("disallow_s2s") ~= false;
	datamanager.add_callback(dm_callback);
end
function module.unload()
	host.disallow_s2s = _saved_disallow_s2s;
	datamanager.remove_callback(dm_callback);
end

module:add_item("auth-provider", new_default_provider(module.host));

