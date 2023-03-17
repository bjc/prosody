-- Prosody IM
-- Copyright (C) 2012 Florian Zeitz
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local random_bytes = require "prosody.util.random".bytes;

local bit = require "prosody.util.bitcompat";
local band = bit.band;
local bor = bit.bor;
local sbit = require "prosody.util.strbitop";
local sxor = sbit.sxor;

local s_char = string.char;
local s_pack = require"prosody.util.struct".pack;
local s_unpack = require"prosody.util.struct".unpack;

local function pack_uint16be(x)
	return s_pack(">I2", x);
end
local function pack_uint64be(x)
	return s_pack(">I8", x);
end

local function read_uint16be(str, pos)
	if type(str) ~= "string" then
		str, pos = str:sub(pos, pos+1), 1;
	end
	return s_unpack(">I2", str, pos);
end
local function read_uint64be(str, pos)
	if type(str) ~= "string" then
		str, pos = str:sub(pos, pos+7), 1;
	end
	return s_unpack(">I8", str, pos);
end

local function parse_frame_header(frame)
	if frame:len() < 2 then return; end

	local byte1, byte2 = frame:byte(1, 2);
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
	if frame:len() < header_length then return; end

	if length_bytes == 2 then
		result.length = read_uint16be(frame, 3);
	elseif length_bytes == 8 then
		result.length = read_uint64be(frame, 3);
	end

	if result.MASK then
		result.key = frame:sub(length_bytes+3, length_bytes+6);
	end

	return result, header_length;
end

-- XORs the string `str` with the array of bytes `key`
-- TODO: optimize
local function apply_mask(str, key, from, to)
	return sxor(str:sub(from or 1, to or -1), key);
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
	if result == nil or frame:len() < (pos + result.length) then return nil, nil, result; end
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
		key = desc.key
		if not key then
			key = random_bytes(4);
		end
		b2 = bor(b2, 0x80);
		data = apply_mask(data, key);
	end

	return s_char(b1, b2) .. length_extra .. key .. data
end

local function parse_close(data)
	local code, message
	if #data >= 2 then
		code = read_uint16be(data, 1);
		if #data > 2 then
			message = data:sub(3);
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
