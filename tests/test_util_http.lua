-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

function urlencode(urlencode)
	assert_equal(urlencode("helloworld123"), "helloworld123", "Normal characters not escaped");
	assert_equal(urlencode("hello world"), "hello%20world", "Spaces escaped");
	assert_equal(urlencode("This & that = something"), "This%20%26%20that%20%3d%20something", "Important URL chars escaped");
end

function urldecode(urldecode)
	assert_equal("helloworld123", urldecode("helloworld123"), "Normal characters not escaped");
	assert_equal("hello world", urldecode("hello%20world"), "Spaces escaped");
	assert_equal("This & that = something", urldecode("This%20%26%20that%20%3d%20something"), "Important URL chars escaped");
	assert_equal("This & that = something", urldecode("This%20%26%20that%20%3D%20something"), "Important URL chars escaped");
end

function formencode(formencode)
	assert_equal(formencode({ { name = "one", value = "1"}, { name = "two", value = "2" } }), "one=1&two=2", "Form encoded");
	assert_equal(formencode({ { name = "one two", value = "1"}, { name = "two one&", value = "2" } }), "one+two=1&two+one%26=2", "Form encoded");
end

function formdecode(formdecode)
	local t = formdecode("one=1&two=2");
	assert_table(t[1]);
	assert_equal(t[1].name, "one"); assert_equal(t[1].value, "1");
	assert_table(t[2]);
	assert_equal(t[2].name, "two"); assert_equal(t[2].value, "2");

	local t = formdecode("one+two=1&two+one%26=2");
	assert_equal(t[1].name, "one two"); assert_equal(t[1].value, "1");
	assert_equal(t[2].name, "two one&"); assert_equal(t[2].value, "2");
end
