-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


function new(new, multitable)
	local mt = new();
	assert_table(mt, "Multitable is a table");
	assert_function(mt.add, "Multitable has method add");
	assert_function(mt.get, "Multitable has method get");
	assert_function(mt.remove, "Multitable has method remove");

	get(mt.get, multitable);
end

function get(get, multitable)
	local function has_items(list, ...)
		local should_have = {};
		if select('#', ...) > 0 then
			assert_table(list, "has_items: list is table", 3);
		else
			assert_is_not(list and #list > 0, "No items, and no list");
			return true, "has-all";
		end
		for n=1,select('#', ...) do should_have[select(n, ...)] = true; end
		for n, item in ipairs(list) do
			if not should_have[item] then return false, "too-many"; end
			should_have[item] = nil;
		end
		if next(should_have) then
			return false, "not-enough";
		end
		return true, "has-all";
	end
	local function assert_has_all(message, list, ...)
		return assert_equal(select(2, has_items(list, ...)), "has-all", message or "List has all expected items, and no more", 2);
	end

	local mt = multitable.new();

	local trigger1, trigger2, trigger3 = {}, {}, {};
	local item1, item2, item3 = {}, {}, {};

	assert_has_all("Has no items with trigger1", mt:get(trigger1));


	mt:add(1, 2, 3, item1);

	assert_has_all("Has item1 for 1, 2, 3", mt:get(1, 2, 3), item1);

-- Doesn't support nil
--[[	mt:add(nil, item1);
	mt:add(nil, item2);
	mt:add(nil, item3);

	assert_has_all("Has all items with (nil)", mt:get(nil), item1, item2, item3);
]]
end
