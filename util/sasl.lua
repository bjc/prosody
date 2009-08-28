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
local tostring = tostring;
local st = require "util.stanza";
local generate_uuid = require "util.uuid".generate;
local pairs, ipairs = pairs, ipairs;
local t_insert, t_concat = table.insert, table.concat;
local to_byte, to_char = string.byte, string.char;
local to_unicode = require "util.encodings".idna.to_unicode;
local s_match = string.match;
local gmatch = string.gmatch
local string = string
local math = require "math"
local type = type
local error = error
local print = print
local setmetatable = setmetatable;
local assert = assert;

require "util.iterators"
local keys = keys

local array = require "util.array"
module "sasl"

--[[
Authentication Backend Prototypes:

plain:
	function(username, realm)
		return password, state;
	end

plain-test:
	function(username, realm, password)
		return true or false, state;
	end

digest-md5:
	function(username, realm, encoding)
		return digesthash, state;
	end

digest-md5-test:
	function(username, realm, encoding, digesthash)
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
function new(realm, profile)
	sasl_i = {profile = profile};
	sasl_i.realm = realm;
	return setmetatable(sasl_i, method);
end

-- get a list of possible SASL mechanims to use
function method:mechanisms()
	local mechanisms = {}
	for backend, f in pairs(self.profile) do
		print(backend)
		if backend_mechanism[backend] then
			for _, mechanism in ipairs(backend_mechanism[backend]) do
				mechanisms[mechanism] = true;
			end
		end
	end
	self["possible_mechanisms"] = mechanisms;
	return array.collect(keys(mechanisms));
end

-- select a mechanism to use
function method:select(mechanism)
	self.mech_i = mechanisms[mechanism]
	if self.mech_i == nil then 
		return false;
	end
	return true;
end

-- feed new messages to process into the library
function method:process(message)
	if message == "" or message == nil then return "failure", "malformed-request" end
	return self.mech_i(self, message);
end

--=========================
--SASL PLAIN according to RFC 4616
local function sasl_mechanism_plain(self, message)
	local response = message
	local authorization = s_match(response, "([^%z]+)")
	local authentication = s_match(response, "%z([^%z]+)%z")
	local password = s_match(response, "%z[^%z]+%z([^%z]+)")

	if authentication == nil or password == nil then
		return "failure", "malformed-request";
	end

	local correct, state = false, false;
	if self.profile.plain then
		local correct_password;
		correct_password, state = self.profile.plain(authentication, self.realm);
		if correct_password == password then correct = true; else correct = false; end
	elseif self.profile.plain_test then
		correct, state = self.profile.plain_test(authentication, self.realm, password);
	end

	self.username = authentication
	if not state then
		return "failure", "account-disabled";
	end

	if correct then
		return "success";
	else
		return "failure", "not-authorized";
	end
end
registerMechanism("PLAIN", {"plain", "plain_test"}, sasl_mechanism_plain);

--=========================
--SASL DIGEST-MD5 according to RFC 2831
local function sasl_mechanism_digest_md5(self, message)
	--TODO complete support for authzid

	local function serialize(message)
		local data = ""

		if type(message) ~= "table" then error("serialize needs an argument of type table.") end

		-- testing all possible values
		if message["realm"] then data = data..[[realm="]]..message.realm..[[",]] end
		if message["nonce"] then data = data..[[nonce="]]..message.nonce..[[",]] end
		if message["qop"] then data = data..[[qop="]]..message.qop..[[",]] end
		if message["charset"] then data = data..[[charset=]]..message.charset.."," end
		if message["algorithm"] then data = data..[[algorithm=]]..message.algorithm.."," end
		if message["rspauth"] then data = data..[[rspauth=]]..message.rspauth.."," end
		data = data:gsub(",$", "")
		return data
	end

	local function utf8tolatin1ifpossible(passwd)
		local i = 1;
		while i <= #passwd do
			local passwd_i = to_byte(passwd:sub(i, i));
			if passwd_i > 0x7F then
				if passwd_i < 0xC0 or passwd_i > 0xC3 then
					return passwd;
				end
				i = i + 1;
				passwd_i = to_byte(passwd:sub(i, i));
				if passwd_i < 0x80 or passwd_i > 0xBF then
					return passwd;
				end
			end
			i = i + 1;
		end

		local p = {};
		local j = 0;
		i = 1;
		while (i <= #passwd) do
			local passwd_i = to_byte(passwd:sub(i, i));
			if passwd_i > 0x7F then
				i = i + 1;
				local passwd_i_1 = to_byte(passwd:sub(i, i));
				t_insert(p, to_char(passwd_i%4*64 + passwd_i_1%64)); -- I'm so clever
			else
				t_insert(p, to_char(passwd_i));
			end
			i = i + 1;
		end
		return t_concat(p);
	end
	local function latin1toutf8(str)
		local p = {};
		for ch in gmatch(str, ".") do
			ch = to_byte(ch);
			if (ch < 0x80) then
				t_insert(p, to_char(ch));
			elseif (ch < 0xC0) then
				t_insert(p, to_char(0xC2, ch));
			else
				t_insert(p, to_char(0xC3, ch - 64));
			end
		end
		return t_concat(p);
	end
	local function parse(data)
		local message = {}
		for k, v in gmatch(data, [[([%w%-]+)="?([^",]*)"?,?]]) do -- FIXME The hacky regex makes me shudder
			message[k] = v;
		end
		return message;
	end

	if not self.nonce then
		self.nonce = generate_uuid();
		self.step = 0;
		self.nonce_count = {};
	end

	self.step = self.step + 1;
	if (self.step == 1) then
		local challenge = serialize({	nonce = object.nonce,
										qop = "auth",
										charset = "utf-8",
										algorithm = "md5-sess",
										realm = self.realm});
		return "challenge", challenge;
	elseif (self.step == 2) then
		local response = parse(message);
		-- check for replay attack
		if response["nc"] then
			if self.nonce_count[response["nc"]] then return "failure", "not-authorized" end
		end

		-- check for username, it's REQUIRED by RFC 2831
		if not response["username"] then
			return "failure", "malformed-request";
		end
		self["username"] = response["username"];

		-- check for nonce, ...
		if not response["nonce"] then
			return "failure", "malformed-request";
		else
			-- check if it's the right nonce
			if response["nonce"] ~= tostring(self.nonce) then return "failure", "malformed-request" end
		end

		if not response["cnonce"] then return "failure", "malformed-request", "Missing entry for cnonce in SASL message." end
		if not response["qop"] then response["qop"] = "auth" end

		if response["realm"] == nil or response["realm"] == "" then
			response["realm"] = "";
		elseif response["realm"] ~= self.realm then
			return "failure", "not-authorized", "Incorrect realm value";
		end

		local decoder;
		if response["charset"] == nil then
			decoder = utf8tolatin1ifpossible;
		elseif response["charset"] ~= "utf-8" then
			return "failure", "incorrect-encoding", "The client's response uses "..response["charset"].." for encoding with isn't supported by sasl.lua. Supported encodings are latin or utf-8.";
		end

		local domain = "";
		local protocol = "";
		if response["digest-uri"] then
			protocol, domain = response["digest-uri"]:match("(%w+)/(.*)$");
			if protocol == nil or domain == nil then return "failure", "malformed-request" end
		else
			return "failure", "malformed-request", "Missing entry for digest-uri in SASL message."
		end

		--TODO maybe realm support
		self.username = response["username"];
		local password_encoding, Y = self.credentials_handler("DIGEST-MD5", response["username"], self.realm, response["realm"], decoder);
		if Y == nil then return "failure", "not-authorized"
		elseif Y == false then return "failure", "account-disabled" end
		local A1 = "";
		if response.authzid then
			if response.authzid == self.username.."@"..self.realm then
				-- COMPAT
				log("warn", "Client is violating XMPP RFC. See section 6.1 of RFC 3920.");
				A1 = Y..":"..response["nonce"]..":"..response["cnonce"]..":"..response.authzid;
			else
				A1 = "?";
			end
		else
			A1 = Y..":"..response["nonce"]..":"..response["cnonce"];
		end
		local A2 = "AUTHENTICATE:"..protocol.."/"..domain;

		local HA1 = md5(A1, true);
		local HA2 = md5(A2, true);

		local KD = HA1..":"..response["nonce"]..":"..response["nc"]..":"..response["cnonce"]..":"..response["qop"]..":"..HA2;
		local response_value = md5(KD, true);

		if response_value == response["response"] then
			-- calculate rspauth
			A2 = ":"..protocol.."/"..domain;

			HA1 = md5(A1, true);
			HA2 = md5(A2, true);

			KD = HA1..":"..response["nonce"]..":"..response["nc"]..":"..response["cnonce"]..":"..response["qop"]..":"..HA2
			local rspauth = md5(KD, true);
			self.authenticated = true;
			return "challenge", serialize({rspauth = rspauth});
		else
			return "failure", "not-authorized", "The response provided by the client doesn't match the one we calculated."
		end
	elseif self.step == 3 then
		if self.authenticated ~= nil then return "success"
		else return "failure", "malformed-request" end
	end
end

return _M;
