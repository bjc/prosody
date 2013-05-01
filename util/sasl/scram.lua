-- sasl.lua v0.4
-- Copyright (C) 2008-2010 Tobias Markmann
--
--	  All rights reserved.
--
--	  Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
--
--		  * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
--		  * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
--		  * Neither the name of Tobias Markmann nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
--
--	  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

local s_match = string.match;
local type = type
local string = string
local base64 = require "util.encodings".base64;
local hmac_sha1 = require "util.hashes".hmac_sha1;
local sha1 = require "util.hashes".sha1;
local Hi = require "util.hashes".scram_Hi_sha1;
local generate_uuid = require "util.uuid".generate;
local saslprep = require "util.encodings".stringprep.saslprep;
local nodeprep = require "util.encodings".stringprep.nodeprep;
local log = require "util.logger".init("sasl");
local t_concat = table.concat;
local char = string.char;
local byte = string.byte;

module "sasl.scram"

--=========================
--SASL SCRAM-SHA-1 according to RFC 5802

--[[
Supported Authentication Backends

scram_{MECH}:
	-- MECH being a standard hash name (like those at IANA's hash registry) with '-' replaced with '_'
	function(username, realm)
		return stored_key, server_key, iteration_count, salt, state;
	end
]]

local default_i = 4096

local function bp( b )
	local result = ""
	for i=1, b:len() do
		result = result.."\\"..b:byte(i)
	end
	return result
end

local xor_map = {0;1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;1;0;3;2;5;4;7;6;9;8;11;10;13;12;15;14;2;3;0;1;6;7;4;5;10;11;8;9;14;15;12;13;3;2;1;0;7;6;5;4;11;10;9;8;15;14;13;12;4;5;6;7;0;1;2;3;12;13;14;15;8;9;10;11;5;4;7;6;1;0;3;2;13;12;15;14;9;8;11;10;6;7;4;5;2;3;0;1;14;15;12;13;10;11;8;9;7;6;5;4;3;2;1;0;15;14;13;12;11;10;9;8;8;9;10;11;12;13;14;15;0;1;2;3;4;5;6;7;9;8;11;10;13;12;15;14;1;0;3;2;5;4;7;6;10;11;8;9;14;15;12;13;2;3;0;1;6;7;4;5;11;10;9;8;15;14;13;12;3;2;1;0;7;6;5;4;12;13;14;15;8;9;10;11;4;5;6;7;0;1;2;3;13;12;15;14;9;8;11;10;5;4;7;6;1;0;3;2;14;15;12;13;10;11;8;9;6;7;4;5;2;3;0;1;15;14;13;12;11;10;9;8;7;6;5;4;3;2;1;0;};

local result = {};
local function binaryXOR( a, b )
	for i=1, #a do
		local x, y = byte(a, i), byte(b, i);
		local lowx, lowy = x % 16, y % 16;
		local hix, hiy = (x - lowx) / 16, (y - lowy) / 16;
		local lowr, hir = xor_map[lowx * 16 + lowy + 1], xor_map[hix * 16 + hiy + 1];
		local r = hir * 16 + lowr;
		result[i] = char(r)
	end
	return t_concat(result);
end

local function validate_username(username, _nodeprep)
	-- check for forbidden char sequences
	for eq in username:gmatch("=(.?.?)") do
		if eq ~= "2C" and eq ~= "3D" then
			return false
		end
	end
	
	-- replace =2C with , and =3D with =
	username = username:gsub("=2C", ",");
	username = username:gsub("=3D", "=");
	
	-- apply SASLprep
	username = saslprep(username);

	if username and _nodeprep ~= false then
		username = (_nodeprep or nodeprep)(username);
	end

	return username and #username>0 and username;
end

local function hashprep(hashname)
	return hashname:lower():gsub("-", "_");
end

function getAuthenticationDatabaseSHA1(password, salt, iteration_count)
	if type(password) ~= "string" or type(salt) ~= "string" or type(iteration_count) ~= "number" then
		return false, "inappropriate argument types"
	end
	if iteration_count < 4096 then
		log("warn", "Iteration count < 4096 which is the suggested minimum according to RFC 5802.")
	end
	local salted_password = Hi(password, salt, iteration_count);
	local stored_key = sha1(hmac_sha1(salted_password, "Client Key"))
	local server_key = hmac_sha1(salted_password, "Server Key");
	return true, stored_key, server_key
end

local function scram_gen(hash_name, H_f, HMAC_f)
	local function scram_hash(self, message)
		if not self.state then self["state"] = {} end
	
		if type(message) ~= "string" or #message == 0 then return "failure", "malformed-request" end
		if not self.state.name then
			-- we are processing client_first_message
			local client_first_message = message;
			
			-- TODO: fail if authzid is provided, since we don't support them yet
			self.state["client_first_message"] = client_first_message;
			self.state["gs2_cbind_flag"], self.state["authzid"], self.state["name"], self.state["clientnonce"]
				= client_first_message:match("^(%a),(.*),n=(.*),r=([^,]*).*");

			-- we don't do any channel binding yet
			if self.state.gs2_cbind_flag ~= "n" and self.state.gs2_cbind_flag ~= "y" then
				return "failure", "malformed-request";
			end

			if not self.state.name or not self.state.clientnonce then
				return "failure", "malformed-request", "Channel binding isn't support at this time.";
			end
		
			self.state.name = validate_username(self.state.name, self.profile.nodeprep);
			if not self.state.name then
				log("debug", "Username violates either SASLprep or contains forbidden character sequences.")
				return "failure", "malformed-request", "Invalid username.";
			end
		
			self.state["servernonce"] = generate_uuid();
			
			-- retreive credentials
			if self.profile.plain then
				local password, state = self.profile.plain(self, self.state.name, self.realm)
				if state == nil then return "failure", "not-authorized"
				elseif state == false then return "failure", "account-disabled" end
				
				password = saslprep(password);
				if not password then
					log("debug", "Password violates SASLprep.");
					return "failure", "not-authorized", "Invalid password."
				end

				self.state.salt = generate_uuid();
				self.state.iteration_count = default_i;

				local succ = false;
				succ, self.state.stored_key, self.state.server_key = getAuthenticationDatabaseSHA1(password, self.state.salt, default_i, self.state.iteration_count);
				if not succ then
					log("error", "Generating authentication database failed. Reason: %s", self.state.stored_key);
					return "failure", "temporary-auth-failure";
				end
			elseif self.profile["scram_"..hashprep(hash_name)] then
				local stored_key, server_key, iteration_count, salt, state = self.profile["scram_"..hashprep(hash_name)](self, self.state.name, self.realm);
				if state == nil then return "failure", "not-authorized"
				elseif state == false then return "failure", "account-disabled" end
				
				self.state.stored_key = stored_key;
				self.state.server_key = server_key;
				self.state.iteration_count = iteration_count;
				self.state.salt = salt
			end
		
			local server_first_message = "r="..self.state.clientnonce..self.state.servernonce..",s="..base64.encode(self.state.salt)..",i="..self.state.iteration_count;
			self.state["server_first_message"] = server_first_message;
			return "challenge", server_first_message
		else
			-- we are processing client_final_message
			local client_final_message = message;
			
			self.state["channelbinding"], self.state["nonce"], self.state["proof"] = client_final_message:match("^c=(.*),r=(.*),.*p=(.*)");
	
			if not self.state.proof or not self.state.nonce or not self.state.channelbinding then
				return "failure", "malformed-request", "Missing an attribute(p, r or c) in SASL message.";
			end

			if self.state.nonce ~= self.state.clientnonce..self.state.servernonce then
				return "failure", "malformed-request", "Wrong nonce in client-final-message.";
			end
			
			local ServerKey = self.state.server_key;
			local StoredKey = self.state.stored_key;
			
			local AuthMessage = "n=" .. s_match(self.state.client_first_message,"n=(.+)") .. "," .. self.state.server_first_message .. "," .. s_match(client_final_message, "(.+),p=.+")
			local ClientSignature = HMAC_f(StoredKey, AuthMessage)
			local ClientKey = binaryXOR(ClientSignature, base64.decode(self.state.proof))
			local ServerSignature = HMAC_f(ServerKey, AuthMessage)

			if StoredKey == H_f(ClientKey) then
				local server_final_message = "v="..base64.encode(ServerSignature);
				self["username"] = self.state.name;
				return "success", server_final_message;
			else
				return "failure", "not-authorized", "The response provided by the client doesn't match the one we calculated.";
			end
		end
	end
	return scram_hash;
end

function init(registerMechanism)
	local function registerSCRAMMechanism(hash_name, hash, hmac_hash)
		registerMechanism("SCRAM-"..hash_name, {"plain", "scram_"..(hashprep(hash_name))}, scram_gen(hash_name:lower(), hash, hmac_hash));
	end

	registerSCRAMMechanism("SHA-1", sha1, hmac_sha1);
end

return _M;
