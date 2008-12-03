-- Prosody IM v0.1
-- Copyright (C) 2008 Matthew Wild
-- Copyright (C) 2008 Waqas Hussain
-- 
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- as published by the Free Software Foundation; either version 2
-- of the License, or (at your option) any later version.
-- 
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- 
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
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
	assert_equal(csp(r3, r5), true);

	assert_equal(csp(r4, r1), false);
	assert_equal(csp(r4, r2), false);
	assert_equal(csp(r4, r3), false);
	assert_equal(csp(r4, r4), false);
	assert_equal(csp(r4, r5), true);

	assert_equal(csp(r5, r1), false);
	assert_equal(csp(r5, r2), false);
	assert_equal(csp(r5, r3), false);
	assert_equal(csp(r5, r4), false);
	assert_equal(csp(r5, r5), false);

end
