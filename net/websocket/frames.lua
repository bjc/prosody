-- Prosody IM
-- Copyright (C) 2012 Florian Zeitz
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local softreq = require "util.dependencies".softreq;
local log = require "util.logger".init "websocket.frames";
local random_bytes = require "util.random".bytes;

local bit = softreq"bit" or softreq"bit32";
if not bit then log("error", "No bit module found. Either LuaJIT 2, lua-bitop or Lua 5.2 is required"); end
local band = bit.band;
local bor = bit.bor;
local bxor = bit.bxor;
local lshift = bit.lshift;
local rshift = bit.rshift;

local t_concat = table.concat;
local s_byte = string.byte;
local s_char= string.char;
local s_sub = string.sub;

local function read_uint16be(str, pos)
	local l1, l2 = s_byte(str, pos, pos+1);
	return l1*256 + l2;
end
-- FIXME: this may lose precision
local function read_uint64be(str, pos)
	local l1, l2, l3, l4, l5, l6, l7, l8 = s_byte(str, pos, pos+7);
	return lshift(l1, 56) + lshift(l2, 48) + lshift(l3, 40) + lshift(l4, 32)
		+ lshift(l5, 24) + lshift(l6, 16) + lshift(l7, 8) + l8;
end
local function pack_uint16be(x)
	return s_char(rshift(x, 8), band(x, 0xFF));
end
local function get_byte(x, n)
	return band(rshift(x, n), 0xFF);
end
local function pack_uint64be(x)
	return s_char(rshift(x, 56), get_byte(x, 48), get_byte(x, 40), get_byte(x, 32),
		get_byte(x, 24), get_byte(x, 16), get_byte(x, 8), band(x, 0xFF));
end

local function parse_frame_header(frame)
	if #frame < 2 then return; end

	local byte1, byte2 = s_byte(frame, 1, 2);
	local result = {
		FIN = band(byte1, 0x80) > 0;
		RSV1 = band(byte1, 0x40) > 0;
		RSV2 = band(byte1, 0x20) > 0;
		RSV3 = band(byte1, 0x10) > 0;
		opcode = band(byte1, 0x0F);

		MASK = band(byte2, 0x80) > 0;
		length = band(byte2, 0x7F);
	};

	local length_bytes = 0;
	if result.length == 126 then
		length_bytes = 2;
	elseif result.length == 127 then
		length_bytes = 8;
	end

	local header_length = 2 + length_bytes + (result.MASK and 4 or 0);
	if #frame < header_length then return; end

	if length_bytes == 2 then
		result.length = read_uint16be(frame, 3);
	elseif length_bytes == 8 then
		result.length = read_uint64be(frame, 3);
	end

	if result.MASK then
		result.key = { s_byte(frame, length_bytes+3, length_bytes+6) };
	end

	return result, header_length;
end

-- XORs the string `str` with the array of bytes `key`
-- TODO: optimize
local function apply_mask(str, key, from, to)
	from = from or 1
	if from < 0 then from = #str + from + 1 end -- negative indicies
	to = to or #str
	if to < 0 then to = #str + to + 1 end -- negative indicies
	local key_len = #key
	local counter = 0;
	local data = {};
	for i = from, to do
		local key_index = counter%key_len + 1;
		counter = counter + 1;
		data[counter] = s_char(bxor(key[key_index], s_byte(str, i)));
	end
	return t_concat(data);
end

local function parse_frame_body(frame, header, pos)
	if header.MASK then
		return apply_mask(frame, header.key, pos, pos + header.length - 1);
	else
		return frame:sub(pos, pos + header.length - 1);
	end
end

local function parse_frame(frame)
	local result, pos = parse_frame_header(frame);
	if result == nil or #frame < (pos + result.length) then return; end
	result.data = parse_frame_body(frame, result, pos+1);
	return result, pos + result.length;
end

local function build_frame(desc)
	local data = desc.data or "";

	assert(desc.opcode and desc.opcode >= 0 and desc.opcode <= 0xF, "Invalid WebSocket opcode");
	if desc.opcode >= 0x8 then
		-- RFC 6455 5.5
		assert(#data <= 125, "WebSocket control frames MUST have a payload length of 125 bytes or less.");
	end

	local b1 = bor(desc.opcode,
		desc.FIN and 0x80 or 0,
		desc.RSV1 and 0x40 or 0,
		desc.RSV2 and 0x20 or 0,
		desc.RSV3 and 0x10 or 0);

	local b2 = #data;
	local length_extra;
	if b2 <= 125 then -- 7-bit length
		length_extra = "";
	elseif b2 <= 0xFFFF then -- 2-byte length
		b2 = 126;
		length_extra = pack_uint16be(#data);
	else -- 8-byte length
		b2 = 127;
		length_extra = pack_uint64be(#data);
	end

	local key = ""
	if desc.MASK then
		local key_a = desc.key
		if key_a then
			key = s_char(unpack(key_a, 1, 4));
		else
			key = random_bytes(4);
			key_a = {key:byte(1,4)};
		end
		b2 = bor(b2, 0x80);
		data = apply_mask(data, key_a);
	end

	return s_char(b1, b2) .. length_extra .. key .. data
end

local function parse_close(data)
	local code, message
	if #data >= 2 then
		code = read_uint16be(data, 1);
		if #data > 2 then
			message = s_sub(data, 3);
		end
	end
	return code, message
end

local function build_close(code, message, mask)
	local data = pack_uint16be(code);
	if message then
		assert(#message<=123, "Close reason must be <=123 bytes");
		data = data .. message;
	end
	return build_frame({
		opcode = 0x8;
		FIN = true;
		MASK = mask;
		data = data;
	});
end

return {
	parse_header = parse_frame_header;
	parse_body = parse_frame_body;
	parse = parse_frame;
	build = build_frame;
	parse_close = parse_close;
	build_close = build_close;
};
