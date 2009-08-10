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

module "sasl"

local method = {}
local mechanisms = {};
local backend_mechanism = {};

-- register a new SASL mechanims
local function registerMechanism(name, backends, f)
	assert(type(name) == "string", "Parameter name MUST be a string.");
	assert(type(backends) == "string" or type(backends) == "table", "Parameter backends MUST be either a string or a table.");
	assert(type(f) == "function", "Parameter f MUST be a function.");
	mechanism[name] = f
	for _, backend_name in ipairs(backend)
end

-- create a new SASL object which can be used to authenticate clients
function new(realm, profile)
	sasl_i = {};
	
	return setmetatable(sasl_i, method);
end

-- get a list of possible SASL mechanims to use
function method:mechanisms()

end

-- select a mechanism to use
function method.select( mechanism )

end

return _M;
