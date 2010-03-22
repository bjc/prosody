-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


function compare_srv_priorities(csp)
	local r1 = { priority = 10, weight = 0 }
	local r2 = { priority = 100, weight = 0 }
	local r3 = { priority = 1000, weight = 2 }
	local r4 = { priority = 1000, weight = 2 }
	local r5 = { priority = 1000, weight = 5 }
	
	assert_equal(csp(r1, r1), false);
	assert_equal(csp(r1, r2), true);
	assert_equal(csp(r1, r3), true);
	assert_equal(csp(r1, r4), true);
	assert_equal(csp(r1, r5), true);

	assert_equal(csp(r2, r1), false);
	assert_equal(csp(r2, r2), false);
	assert_equal(csp(r2, r3), true);
	assert_equal(csp(r2, r4), true);
	assert_equal(csp(r2, r5), true);

	assert_equal(csp(r3, r1), false);
	assert_equal(csp(r3, r2), false);
	assert_equal(csp(r3, r3), false);
	assert_equal(csp(r3, r4), false);
	assert_equal(csp(r3, r5), false);

	assert_equal(csp(r4, r1), false);
	assert_equal(csp(r4, r2), false);
	assert_equal(csp(r4, r3), false);
	assert_equal(csp(r4, r4), false);
	assert_equal(csp(r4, r5), false);

	assert_equal(csp(r5, r1), false);
	assert_equal(csp(r5, r2), false);
	assert_equal(csp(r5, r3), true);
	assert_equal(csp(r5, r4), true);
	assert_equal(csp(r5, r5), false);

end
