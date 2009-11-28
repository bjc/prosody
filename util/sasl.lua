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


local md5 = require "util.hashes".md5;
local log = require "util.logger".init("sasl");
local st = require "util.stanza";
local set = require "util.set";
local array = require "util.array";
local to_unicode = require "util.encodings".idna.to_unicode;

local tostring = tostring;
local pairs, ipairs = pairs, ipairs;
local t_insert, t_concat = table.insert, table.concat;
local s_match = string.match;
local type = type
local error = error
local setmetatable = setmetatable;
local assert = assert;
local require = require;

require "util.iterators"
local keys = keys

local array = require "util.array"
module "sasl"

--[[
Authentication Backend Prototypes:

state = false : disabled
state = true : enabled
state = nil : non-existant

plain:
	function(username, realm)
		return password, state;
	end

plain-test:
	function(username, realm, password)
		return true or false, state;
	end

digest-md5:
	function(username, domain, realm, encoding) -- domain and realm are usually the same; for some broken
												-- implementations it's not
		return digesthash, state;
	end

digest-md5-test:
	function(username, domain, realm, encoding, digesthash)
		return true or false, state;
	end
]]

local method = {};
method.__index = method;
local mechanisms = {};
local backend_mechanism = {};

-- register a new SASL mechanims
local function registerMechanism(name, backends, f)
	assert(type(name) == "string", "Parameter name MUST be a string.");
	assert(type(backends) == "string" or type(backends) == "table", "Parameter backends MUST be either a string or a table.");
	assert(type(f) == "function", "Parameter f MUST be a function.");
	mechanisms[name] = f
	for _, backend_name in ipairs(backends) do
		if backend_mechanism[backend_name] == nil then backend_mechanism[backend_name] = {}; end
		t_insert(backend_mechanism[backend_name], name);
	end
end

-- create a new SASL object which can be used to authenticate clients
function new(realm, profile, forbidden)
	local sasl_i = {profile = profile};
	sasl_i.realm = realm;
	local s = setmetatable(sasl_i, method);
	if forbidden == nil then forbidden = {} end
	s:forbidden(forbidden)
	return s;
end

-- get a fresh clone with the same realm, profiles and forbidden mechanisms
function method:clean_clone()
	return new(self.realm, self.profile, self:forbidden())
end

-- set the forbidden mechanisms
function method:forbidden( restrict )
	if restrict then
		-- set forbidden
		self.restrict = set.new(restrict);
	else
		-- get forbidden
		return array.collect(self.restrict:items());
	end
end

-- get a list of possible SASL mechanims to use
function method:mechanisms()
	local mechanisms = {}
	for backend, f in pairs(self.profile) do
		if backend_mechanism[backend] then
			for _, mechanism in ipairs(backend_mechanism[backend]) do
				if not self.restrict:contains(mechanism) then
					mechanisms[mechanism] = true;
				end
			end
		end
	end
	self["possible_mechanisms"] = mechanisms;
	return array.collect(keys(mechanisms));
end

-- select a mechanism to use
function method:select(mechanism)
	if self.mech_i then
		return false;
	end
	
	self.mech_i = mechanisms[mechanism]
	if self.mech_i == nil then 
		return false;
	end
	return true;
end

-- feed new messages to process into the library
function method:process(message)
	--if message == "" or message == nil then return "failure", "malformed-request" end
	return self.mech_i(self, message);
end

-- load the mechanisms
load_mechs = {"plain", "digest-md5", "anonymous", "scram"}
for _, mech in ipairs(load_mechs) do
	local name = "util.sasl."..mech;
	local m = require(name);
	m.init(registerMechanism)
end

return _M;
