-- sasl.lua v0.4
-- Copyright (C) 2008-2010 Tobias Markmann
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

local s_match = string.match;
local saslprep = require "util.encodings".stringprep.saslprep;
local nodeprep = require "util.encodings".stringprep.nodeprep;
local log = require "util.logger".init("sasl");

local _ENV = nil;

-- ================================
-- SASL PLAIN according to RFC 4616

--[[
Supported Authentication Backends

plain:
	function(username, realm)
		return password, state;
	end

plain_test:
	function(username, password, realm)
		return true or false, state;
	end
]]

local function plain(self, message)
	if not message then
		return "failure", "malformed-request";
	end

	local authorization, authentication, password = s_match(message, "^([^%z]*)%z([^%z]+)%z([^%z]+)");

	if not authorization then
		return "failure", "malformed-request";
	end

	-- SASLprep password and authentication
	authentication = saslprep(authentication);
	password = saslprep(password);

	if (not password) or (password == "") or (not authentication) or (authentication == "") then
		log("debug", "Username or password violates SASLprep.");
		return "failure", "malformed-request", "Invalid username or password.";
	end

	local _nodeprep = self.profile.nodeprep;
	if _nodeprep ~= false then
		authentication = (_nodeprep or nodeprep)(authentication);
		if not authentication or authentication == "" then
			return "failure", "malformed-request", "Invalid username or password."
		end
	end

	local correct, state = false, false;
	if self.profile.plain then
		local correct_password;
		correct_password, state = self.profile.plain(self, authentication, self.realm);
		correct = (correct_password == password);
	elseif self.profile.plain_test then
		correct, state = self.profile.plain_test(self, authentication, password, self.realm);
	end

	self.username = authentication
	if state == false then
		return "failure", "account-disabled";
	elseif state == nil or not correct then
		return "failure", "not-authorized", "Unable to authorize you with the authentication credentials you've sent.";
	end

	return "success";
end

local function init(registerMechanism)
	registerMechanism("PLAIN", {"plain", "plain_test"}, plain);
end

return {
	init = init;
}
