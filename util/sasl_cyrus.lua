-- sasl.lua v0.4
-- Copyright (C) 2008-2009 Tobias Markmann
--
--    All rights reserved.
--
--    Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
--
--        * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
--        * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
--        * Neither the name of Tobias Markmann nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
--
--    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

local cyrussasl = require "cyrussasl";
local log = require "util.logger".init("sasl_cyrus");
local array = require "util.array";

local tostring = tostring;
local pairs, ipairs = pairs, ipairs;
local t_insert, t_concat = table.insert, table.concat;
local s_match = string.match;
local setmetatable = setmetatable

local keys = keys;

local print = print
local pcall = pcall
local s_match, s_gmatch = string.match, string.gmatch

module "sasl_cyrus"

local method = {};
method.__index = method;
local initialized = false;

local function init(service_name)
	if not initialized then
		local st, errmsg = pcall(cyrussasl.server_init, service_name);
		if st then
			initialized = true;
		else
			log("error", "Failed to initialize CyrusSASL: %s", errmsg);
		end
	end
end

-- create a new SASL object which can be used to authenticate clients
function new(realm, service_name)
	local sasl_i = {};

	init(service_name);

	sasl_i.realm = realm;
	sasl_i.service_name = service_name;
	sasl_i.cyrus = cyrussasl.server_new(service_name, nil, realm, nil, nil)
	if sasl_i.cyrus == 0 then
		log("error", "got NULL return value from server_new")
		return nil;
	end
	cyrussasl.setssf(sasl_i.cyrus, 0, 0xffffffff)
	local s = setmetatable(sasl_i, method);
	return s;
end

-- get a fresh clone with the same realm, profiles and forbidden mechanisms
function method:clean_clone()
	return new(self.realm, self.service_name)
end

-- set the forbidden mechanisms
function method:forbidden( restrict )
	log("debug", "Called method:forbidden. NOT IMPLEMENTED.")
	return {}
end

-- get a list of possible SASL mechanims to use
function method:mechanisms()
	local mechanisms = {}
	local cyrus_mechs = cyrussasl.listmech(self.cyrus, nil, "", " ", "")
	for w in s_gmatch(cyrus_mechs, "[^ ]+") do
		mechanisms[w] = true;
	end
	self.mechs = mechanisms
	return array.collect(keys(mechanisms));
end

-- select a mechanism to use
function method:select(mechanism)
	self.mechanism = mechanism;
	if not self.mechs then self:mechanisms(); end
	return self.mechs[mechanism];
end

-- feed new messages to process into the library
function method:process(message)
	local err;
	local data;

	if self.mechanism then
		err, data = cyrussasl.server_start(self.cyrus, self.mechanism, message or "")
	else
		err, data = cyrussasl.server_step(self.cyrus, message or "")
	end

	self.username = cyrussasl.get_username(self.cyrus)

	if (err == 0) then -- SASL_OK
	   return "success", data
	elseif (err == 1) then -- SASL_CONTINUE
	   return "challenge", data
	elseif (err == -4) then -- SASL_NOMECH
	   log("debug", "SASL mechanism not available from remote end")
	   return "failure", 
	     "undefined-condition",
	     "SASL mechanism not available"
	elseif (err == -13) then -- SASL_BADAUTH
	   return "failure", "not-authorized", cyrussasl.get_message( self.cyrus )
	else
	   log("debug", "Got SASL error condition %d", err)
	   return "failure", 
	     "undefined-condition",
	     cyrussasl.get_message( self.cyrus )
	end
end

return _M;
