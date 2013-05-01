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

local tostring = tostring;
local type = type;

local s_gmatch = string.gmatch;
local s_match = string.match;
local t_concat = table.concat;
local t_insert = table.insert;
local to_byte, to_char = string.byte, string.char;

local md5 = require "util.hashes".md5;
local log = require "util.logger".init("sasl");
local generate_uuid = require "util.uuid".generate;
local nodeprep = require "util.encodings".stringprep.nodeprep;

module "sasl.digest-md5"

--=========================
--SASL DIGEST-MD5 according to RFC 2831

--[[
Supported Authentication Backends

digest_md5:
	function(username, domain, realm, encoding) -- domain and realm are usually the same; for some broken
												-- implementations it's not
		return digesthash, state;
	end

digest_md5_test:
	function(username, domain, realm, encoding, digesthash)
		return true or false, state;
	end
]]

local function digest(self, message)
	--TODO complete support for authzid

	local function serialize(message)
		local data = ""

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
		for ch in s_gmatch(str, ".") do
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
		-- COMPAT: %z in the pattern to work around jwchat bug (sends "charset=utf-8\0")
		for k, v in s_gmatch(data, [[([%w%-]+)="?([^",%z]*)"?,?]]) do -- FIXME The hacky regex makes me shudder
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
		local challenge = serialize({	nonce = self.nonce,
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
		local username = response["username"];
		local _nodeprep = self.profile.nodeprep;
		if username and _nodeprep ~= false then
			username = (_nodeprep or nodeprep)(username); -- FIXME charset
		end
		if not username or username == "" then
			return "failure", "malformed-request";
		end
		self.username = username;

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
		local Y, state;
		if self.profile.plain then
			local password, state = self.profile.plain(self, response["username"], self.realm)
			if state == nil then return "failure", "not-authorized"
			elseif state == false then return "failure", "account-disabled" end
			Y = md5(response["username"]..":"..response["realm"]..":"..password);
		elseif self.profile["digest-md5"] then
			Y, state = self.profile["digest-md5"](self, response["username"], self.realm, response["realm"], response["charset"])
			if state == nil then return "failure", "not-authorized"
			elseif state == false then return "failure", "account-disabled" end
		elseif self.profile["digest-md5-test"] then
			-- TODO
		end
		--local password_encoding, Y = self.credentials_handler("DIGEST-MD5", response["username"], self.realm, response["realm"], decoder);
		--if Y == nil then return "failure", "not-authorized"
		--elseif Y == false then return "failure", "account-disabled" end
		local A1 = "";
		if response.authzid then
			if response.authzid == self.username or response.authzid == self.username.."@"..self.realm then
				-- COMPAT
				log("warn", "Client is violating RFC 3920 (section 6.1, point 7).");
				A1 = Y..":"..response["nonce"]..":"..response["cnonce"]..":"..response.authzid;
			else
				return "failure", "invalid-authzid";
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
			--TODO: considering sending the rspauth in a success node for saving one roundtrip; allowed according to http://tools.ietf.org/html/draft-saintandre-rfc3920bis-09#section-7.3.6
			return "challenge", serialize({rspauth = rspauth});
		else
			return "failure", "not-authorized", "The response provided by the client doesn't match the one we calculated."
		end
	elseif self.step == 3 then
		if self.authenticated ~= nil then return "success"
		else return "failure", "malformed-request" end
	end
end

function init(registerMechanism)
	registerMechanism("DIGEST-MD5", {"plain"}, digest);
end

return _M;
