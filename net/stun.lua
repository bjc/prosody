local base64 = require "prosody.util.encodings".base64;
local hashes = require "prosody.util.hashes";
local net = require "prosody.util.net";
local random = require "prosody.util.random";
local struct = require "prosody.util.struct";
local bit32 = require"prosody.util.bitcompat";
local sxor = require"prosody.util.strbitop".sxor;
local new_ip = require "prosody.util.ip".new_ip;

--- Public helpers

-- Following draft-uberti-behave-turn-rest-00, convert a 'secret' string
-- into a username/password pair that can be used to auth to a TURN server
local function get_user_pass_from_secret(secret, ttl, opt_username)
	ttl = ttl or 86400;
	local username;
	if opt_username then
		username = ("%d:%s"):format(os.time() + ttl, opt_username);
	else
		username = ("%d"):format(os.time() + ttl);
	end
	local password = base64.encode(hashes.hmac_sha1(secret, username));
	return username, password, ttl;
end

-- Following RFC 8489 9.2, convert credentials to a HMAC key for signing
local function get_long_term_auth_key(realm, username, password)
	return hashes.md5(username..":"..realm..":"..password);
end

--- Packet building/parsing

local packet_methods = {};
local packet_mt = { __index = packet_methods };

local magic_cookie = string.char(0x21, 0x12, 0xA4, 0x42);

local function lookup_table(t)
	local lookup = {};
	for k, v in pairs(t) do
		lookup[k] = v;
		lookup[v] = k;
	end
	return lookup;
end

local methods = {
	binding = 0x001;
	-- TURN
	allocate = 0x003;
	refresh = 0x004;
	send = 0x006;
	data = 0x007;
	["create-permission"] = 0x008;
	["channel-bind"] = 0x009;
};
local method_lookup = lookup_table(methods);

local classes = {
	request = 0;
	indication = 1;
	success = 2;
	error = 3;
};
local class_lookup = lookup_table(classes);

local addr_families = { "IPv4", "IPv6" };
local addr_family_lookup = lookup_table(addr_families);

local attributes = {
	["mapped-address"] = 0x0001;
	["username"] = 0x0006;
	["message-integrity"] = 0x0008;
	["error-code"] = 0x0009;
	["unknown-attributes"] = 0x000A;
	["realm"] = 0x0014;
	["nonce"] = 0x0015;
	["xor-mapped-address"] = 0x0020;
	["software"] = 0x8022;
	["alternate-server"] = 0x8023;
	["fingerprint"] = 0x8028;
	["message-integrity-sha256"] = 0x001C;
	["password-algorithm"] = 0x001D;
	["userhash"] = 0x001E;
	["password-algorithms"] = 0x8002;
	["alternate-domains"] = 0x8003;

	-- TURN
	["requested-transport"] = 0x0019;
	["xor-peer-address"] = 0x0012;
	["data"] = 0x0013;
	["xor-relayed-address"] = 0x0016;
};
local attribute_lookup = lookup_table(attributes);

function packet_methods:serialize_header(length)
	assert(#self.transaction_id == 12, "invalid transaction id length");
	local header = struct.pack(">I2I2",
		self.type,
		length
	)..magic_cookie..self.transaction_id;
	return header;
end

function packet_methods:serialize()
	local payload = table.concat(self.attributes);
	return self:serialize_header(#payload)..payload;
end

function packet_methods:is_request()
	return bit32.band(self.type, 0x0110) == 0x0000;
end

function packet_methods:is_indication()
	return bit32.band(self.type, 0x0110) == 0x0010;
end

function packet_methods:is_success_resp()
	return bit32.band(self.type, 0x0110) == 0x0100;
end

function packet_methods:is_err_resp()
	return bit32.band(self.type, 0x0110) == 0x0110;
end

function packet_methods:get_method()
	local method = bit32.bor(
		bit32.rshift(bit32.band(self.type, 0x3E00), 2),
		bit32.rshift(bit32.band(self.type, 0x00E0), 1),
		bit32.band(self.type, 0x000F)
	);
	return method, method_lookup[method];
end

function packet_methods:get_class()
	local class = bit32.bor(
		bit32.rshift(bit32.band(self.type, 0x0100), 7),
		bit32.rshift(bit32.band(self.type, 0x0010), 4)
	);
	return class, class_lookup[class];
end

function packet_methods:set_type(method, class)
	if type(method) == "string" then
		method = assert(method_lookup[method:lower()], "unknown method: "..method);
	end
	if type(class) == "string" then
		class = assert(classes[class], "unknown class: "..class);
	end
	self.type = bit32.bor(
		bit32.lshift(bit32.band(method, 0x1F80), 2),
		bit32.lshift(bit32.band(method, 0x0070), 1),
		bit32.band(method, 0x000F),
		bit32.lshift(bit32.band(class, 0x0002), 7),
		bit32.lshift(bit32.band(class, 0x0001), 4)
	);
end

local function _serialize_attribute(attr_type, value)
	local len = #value;
	local padding = string.rep("\0", (4 - len)%4);
	return struct.pack(">I2I2",
		attr_type, len
	)..value..padding;
end

function packet_methods:add_attribute(attr_type, value)
	if type(attr_type) == "string" then
		attr_type = assert(attributes[attr_type], "unknown attribute: "..attr_type);
	end
	table.insert(self.attributes, _serialize_attribute(attr_type, value));
end

function packet_methods:deserialize(bytes)
	local type, len, cookie = struct.unpack(">I2I2I4", bytes);
	assert(#bytes == (len + 20), "incorrect packet length");
	assert(cookie == 0x2112A442, "invalid magic cookie");
	self.type = type;
	self.transaction_id = bytes:sub(9, 20);
	self.attributes = {};
	local pos = 21;
	while pos < #bytes do
		local attr_hdr = bytes:sub(pos, pos+3);
		assert(#attr_hdr == 4, "packet truncated in attribute header");
		local attr_type, attr_len = struct.unpack(">I2I2", attr_hdr); --luacheck: ignore 211/attr_type
		if attr_len == 0 then
			table.insert(self.attributes, attr_hdr);
			pos = pos + 20;
		else
			local data = bytes:sub(pos + 4, pos + 3 + attr_len);
			assert(#data == attr_len, "packet truncated in attribute value");
			table.insert(self.attributes, attr_hdr..data);
			local n_padding = (4 - attr_len)%4;
			pos = pos + 4 + attr_len + n_padding;
		end
	end
	return self;
end

function packet_methods:get_attribute(attr_type, idx)
	idx = math.max(idx or 1, 1);
	if type(attr_type) == "string" then
		attr_type = assert(attribute_lookup[attr_type:lower()], "unknown attribute: "..attr_type);
	end
	for _, attribute in ipairs(self.attributes) do
		if struct.unpack(">I2", attribute) == attr_type then
			if idx == 1 then
				return attribute:sub(5);
			else
				idx = idx - 1;
			end
		end
	end
end

function packet_methods:_unpack_address(data, xor)
	local family, port = struct.unpack("x>BI2", data);
	local addr = data:sub(5);
	if xor then
		port = bit32.bxor(port, 0x2112);
		addr = sxor(addr, magic_cookie..self.transaction_id);
	end
	return {
		family = addr_families[family] or "unknown";
		port = port;
		address = net.ntop(addr);
	};
end

function packet_methods:_pack_address(family, addr, port, xor)
	if xor then
		port = bit32.bxor(port, 0x2112);
		addr = sxor(addr, magic_cookie..self.transaction_id);
	end
	local family_port = struct.pack("x>BI2", family, port);
	return family_port..addr
end

function packet_methods:get_mapped_address()
	local data = self:get_attribute("mapped-address");
	if not data then return; end
	return self:_unpack_address(data, false);
end

function packet_methods:get_xor_mapped_address()
	local data = self:get_attribute("xor-mapped-address");
	if not data then return; end
	return self:_unpack_address(data, true);
end

function packet_methods:add_xor_peer_address(address, port)
	local parsed_ip = assert(new_ip(address));
	local family = assert(addr_family_lookup[parsed_ip.proto], "Unknown IP address family: "..parsed_ip.proto);
	self:add_attribute("xor-peer-address", self:_pack_address(family, parsed_ip.packed, port or 0, true));
end

function packet_methods:get_xor_relayed_address(idx)
	local data = self:get_attribute("xor-relayed-address", idx);
	if not data then return; end
	return self:_unpack_address(data, true);
end

function packet_methods:get_xor_relayed_addresses()
	return {
		self:get_xor_relayed_address(1);
		self:get_xor_relayed_address(2);
	};
end

function packet_methods:add_message_integrity(key)
	-- Add attribute with a dummy value so we can artificially increase
	-- the packet 'length'
	self:add_attribute("message-integrity", string.rep("\0", 20));
	-- Get the packet data, minus the message-integrity attribute itself
	local pkt = self:serialize():sub(1, -25);
	local hash = hashes.hmac_sha1(key, pkt, false);
	self.attributes[#self.attributes] = nil;
	assert(#hash == 20, "invalid hash length");
	self:add_attribute("message-integrity", hash);
end

do
	local transports = {
		udp = 0x11;
	};
	function packet_methods:add_requested_transport(transport)
		local transport_code = transports[transport];
		assert(transport_code, "unsupported transport: "..tostring(transport));
		self:add_attribute("requested-transport", string.char(
			transport_code, 0x00, 0x00, 0x00
		));
	end
end

function packet_methods:get_error()
	local err_attr = self:get_attribute("error-code");
	if not err_attr then
		return nil;
	end
	local number = err_attr:byte(4);
	local class = bit32.band(0x07, err_attr:byte(3));
	local msg = err_attr:sub(5);
	return (class*100)+number, msg;
end

local function new_packet(method, class)
	local p = setmetatable({
		transaction_id = random.bytes(12);
		length = 0;
		attributes = {};
	}, packet_mt);
	p:set_type(method or "binding", class or "request");
	return p;
end

return {
	new_packet = new_packet;
	get_user_pass_from_secret = get_user_pass_from_secret;
	get_long_term_auth_key = get_long_term_auth_key;
};
