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

local s_match = string.match;
local type = type
local string = string
local base64 = require "util.encodings".base64;
local xor = require "bit".bxor
local hmac_sha1 = require "util.hmac".sha1;
local sha1 = require "util.hashes".sha1;
local generate_uuid = require "util.uuid".generate;

module "plain"

--=========================
--SASL SCRAM-SHA-1 according to draft-ietf-sasl-scram-10
local default_i = 4096

local function bp( b )
	local result = ""
	for i=1, b:len() do
		result = result.."\\"..b:byte(i)
	end
	return result
end

local function binaryXOR( a, b )
	if a:len() > b:len() then
		b = string.rep("\0", a:len() - b:len())..b
	elseif string.len(a) < string.len(b) then
		a = string.rep("\0", b:len() - a:len())..a
	end
	local result = ""
	for i=1, a:len() do
		result = result..string.char(xor(a:byte(i), b:byte(i)))
	end
	return result
end

-- hash algorithm independent Hi(PBKDF2) implementation
local function Hi(hmac, str, salt, i)
	local Ust = hmac(str, salt.."\0\0\0\1");
	local res = Ust;	
	for n=1,i-1 do
		Und = hmac(str, Ust)
		res = binaryXOR(res, Und)
		Ust = Und
	end
	return res
end

local function validate_username(username)
	-- check for forbidden char sequences
	for eq in username:gmatch("=(.?.?)") do
		if eq ~= "2D" and eq ~= "3D" then
			return false 
		end 
	end
	
	-- replace =2D with , and =3D with =
	
	-- apply SASLprep
	return username;
end

local function scram_sha_1(self, message)
	if not self.state then self["state"] = {} end
	
	if not self.state.name then
		-- we are processing client_first_message
		local client_first_message = message;
		self.state["client_first_message"] = client_first_message;
		self.state["name"] = client_first_message:match("n=(.+),r=")
		self.state["clientnonce"] = client_first_message:match("r=([^,]+)")
		
		self.state.name = validate_username(self.state.name);
		if not self.state.name or not self.state.clientnonce then
			return "failure", "malformed-request";
		end
		self.state["servernonce"] = generate_uuid();
		self.state["salt"] = generate_uuid();
		
		local server_first_message = "r="..self.state.clientnonce..self.state.servernonce..",s="..base64.encode(self.state.salt)..",i="..default_i;
		self.state["server_first_message"] = server_first_message;
		return "challenge", server_first_message
	else
		if type(message) ~= "string" then return "failure", "malformed-request" end
		-- we are processing client_final_message
		local client_final_message = message;
		
		self.state["proof"] = client_final_message:match("p=(.+)");
		self.state["nonce"] = client_final_message:match("r=(.+),p=");
		self.state["channelbinding"] = client_final_message:match("c=(.+),r=");
		if not self.state.proof or not self.state.nonce or not self.state.channelbinding then
			return "failure", "malformed-request";
		end
		
		local password;
		if self.profile.plain then
			password, state = self.profile.plain(self.state.name, self.realm)
			if state == nil then return "failure", "not-authorized"
			elseif state == false then return "failure", "account-disabled" end
		end
		
		local SaltedPassword = Hi(hmac_sha1, password, self.state.salt, default_i)
		local ClientKey = hmac_sha1(SaltedPassword, "Client Key")
		local ServerKey = hmac_sha1(SaltedPassword, "Server Key")
		local StoredKey = sha1(ClientKey)
		local AuthMessage = "n=" .. s_match(self.state.client_first_message,"n=(.+)") .. "," .. self.state.server_first_message .. "," .. s_match(client_final_message, "(.+),p=.+")
		local ClientSignature = hmac_sha1(StoredKey, AuthMessage)
		local ClientProof     = binaryXOR(ClientKey, ClientSignature)
		local ServerSignature = hmac_sha1(ServerKey, AuthMessage)
		
		if base64.encode(ClientProof) == self.state.proof then
			local server_final_message = "v="..base64.encode(ServerSignature);
			self["username"] = self.state.name;
			return "success", server_final_message;
		else
			return "failure", "not-authorized", "The response provided by the client doesn't match the one we calculated.";
		end
	end
end

function init(registerMechanism)
	registerMechanism("SCRAM-SHA-1", {"plain"}, scram_sha_1);
end

return _M;