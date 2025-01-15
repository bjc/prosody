-- Compatibility layer for bitwise operations

-- First try the bit32 lib
-- Lua 5.3 has it with compat enabled
-- Lua 5.2 has it by default
if rawget(_G, "bit32") then
	return _G.bit32;
end

do
	-- Lua 5.3 and 5.4 would be able to use native infix operators
	local ok, bitop = pcall(require, "prosody.util.bit53")
	if ok then
		return bitop;
	end
end

error "No bit module found. See https://prosody.im/doc/depends#bitop";
