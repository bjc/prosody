-- Prosody IM v0.2
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



function get(get, config)
	config.set("example.com", "test", "testkey", 123);
	assert_equal(get("example.com", "test", "testkey"), 123, "Retrieving a set key");

	config.set("*", "test", "testkey1", 321);
	assert_equal(get("*", "test", "testkey1"), 321, "Retrieving a set global key");
	assert_equal(get("example.com", "test", "testkey1"), 321, "Retrieving a set key of undefined host, of which only a globally set one exists");
	
	config.set("example.com", "test", ""); -- Creates example.com host in config
	assert_equal(get("example.com", "test", "testkey1"), 321, "Retrieving a set key, of which only a globally set one exists");
	
	assert_equal(get(), nil, "No parameters to get()");
	assert_equal(get("undefined host"), nil, "Getting for undefined host");
	assert_equal(get("undefined host", "undefined section"), nil, "Getting for undefined host & section");
	assert_equal(get("undefined host", "undefined section", "undefined key"), nil, "Getting for undefined host & section & key");

	assert_equal(get("example.com", "undefined section", "testkey"), nil, "Defined host, undefined section");
end

function set(set, u)
	assert_equal(set("*"), false, "Set with no section/key");
	assert_equal(set("*", "set_test"), false, "Set with no key");	

	assert_equal(set("*", "set_test", "testkey"), true, "Setting a nil global value");
	assert_equal(set("*", "set_test", "testkey", 123), true, "Setting a global value");
end

