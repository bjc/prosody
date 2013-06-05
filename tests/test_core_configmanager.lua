-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



function get(get, config)
	config.set("example.com", "testkey", 123);
	assert_equal(get("example.com", "testkey"), 123, "Retrieving a set key");

	config.set("*", "testkey1", 321);
	assert_equal(get("*", "testkey1"), 321, "Retrieving a set global key");
	assert_equal(get("example.com", "testkey1"), 321, "Retrieving a set key of undefined host, of which only a globally set one exists");
	
	config.set("example.com", ""); -- Creates example.com host in config
	assert_equal(get("example.com", "testkey1"), 321, "Retrieving a set key, of which only a globally set one exists");
	
	assert_equal(get(), nil, "No parameters to get()");
	assert_equal(get("undefined host"), nil, "Getting for undefined host");
	assert_equal(get("undefined host", "undefined key"), nil, "Getting for undefined host & key");
end

function set(set, u)
	assert_equal(set("*"), false, "Set with no key");

	assert_equal(set("*", "set_test", "testkey"), true, "Setting a nil global value");
	assert_equal(set("*", "set_test", "testkey", 123), true, "Setting a global value");
end

