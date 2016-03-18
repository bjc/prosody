-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

function join(join)
	assert_equal(join("a", "b", "c"), "a@b/c", "builds full JID");
	assert_equal(join("a", "b", nil), "a@b", "builds bare JID");
	assert_equal(join(nil, "b", "c"), "b/c", "builds full host JID");
	assert_equal(join(nil, "b", nil), "b", "builds bare host JID");
	assert_equal(join(nil, nil, nil), nil, "invalid JID is nil");
	assert_equal(join("a", nil, nil), nil, "invalid JID is nil");
	assert_equal(join(nil, nil, "c"), nil, "invalid JID is nil");
	assert_equal(join("a", nil, "c"), nil, "invalid JID is nil");
end


function split(split)
	function test(input_jid, expected_node, expected_server, expected_resource)
		local rnode, rserver, rresource = split(input_jid);
		assert_equal(expected_node, rnode, "split("..tostring(input_jid)..") failed");
		assert_equal(expected_server, rserver, "split("..tostring(input_jid)..") failed");
		assert_equal(expected_resource, rresource, "split("..tostring(input_jid)..") failed");
	end

	-- Valid JIDs
	test("node@server", 		"node", "server", nil		);
	test("node@server/resource", 	"node", "server", "resource"        );
	test("server", 			nil, 	"server", nil               );
	test("server/resource", 	nil, 	"server", "resource"        );
	test("server/resource@foo", 	nil, 	"server", "resource@foo"    );
	test("server/resource@foo/bar",	nil, 	"server", "resource@foo/bar");

	-- Always invalid JIDs
	test(nil,                nil, nil, nil);
	test("node@/server",     nil, nil, nil);
	test("@server",          nil, nil, nil);
	test("@server/resource", nil, nil, nil);
	test("@/resource", nil, nil, nil);
end

function bare(bare)
	assert_equal(bare("user@host"), "user@host", "bare JID remains bare");
	assert_equal(bare("host"), "host", "Host JID remains host");
	assert_equal(bare("host/resource"), "host", "Host JID with resource becomes host");
	assert_equal(bare("user@host/resource"), "user@host", "user@host JID with resource becomes user@host");
	assert_equal(bare("user@/resource"), nil, "invalid JID is nil");
	assert_equal(bare("@/resource"), nil, "invalid JID is nil");
	assert_equal(bare("@/"), nil, "invalid JID is nil");
	assert_equal(bare("/"), nil, "invalid JID is nil");
	assert_equal(bare(""), nil, "invalid JID is nil");
	assert_equal(bare("@"), nil, "invalid JID is nil");
	assert_equal(bare("user@"), nil, "invalid JID is nil");
	assert_equal(bare("user@@"), nil, "invalid JID is nil");
	assert_equal(bare("user@@host"), nil, "invalid JID is nil");
	assert_equal(bare("user@@host/resource"), nil, "invalid JID is nil");
	assert_equal(bare("user@host/"), nil, "invalid JID is nil");
end

function compare(compare)
	assert_equal(compare("host", "host"), true, "host should match");
	assert_equal(compare("host", "other-host"), false, "host should not match");
	assert_equal(compare("other-user@host/resource", "host"), true, "host should match");
	assert_equal(compare("other-user@host", "user@host"), false, "user should not match");
	assert_equal(compare("user@host", "host"), true, "host should match");
	assert_equal(compare("user@host/resource", "host"), true, "host should match");
	assert_equal(compare("user@host/resource", "user@host"), true, "user and host should match");
	assert_equal(compare("user@other-host", "host"), false, "host should not match");
	assert_equal(compare("user@other-host", "user@host"), false, "host should not match");
end

function node(node)
	local function test(jid, expected_node)
		assert_equal(node(jid), expected_node, "Unexpected node for "..tostring(jid));
	end

	test("example.com", nil);
	test("foo.example.com", nil);
	test("foo.example.com/resource", nil);
	test("foo.example.com/some resource", nil);
	test("foo.example.com/some@resource", nil);

	test("foo@foo.example.com/some@resource", "foo");
	test("foo@example/some@resource", "foo");

	test("foo@example/@resource", "foo");
	test("foo@example@resource", nil);
	test("foo@example", "foo");
	test("foo", nil);

	test(nil, nil);
end

function host(host)
	local function test(jid, expected_host)
		assert_equal(host(jid), expected_host, "Unexpected host for "..tostring(jid));
	end

	test("example.com", "example.com");
	test("foo.example.com", "foo.example.com");
	test("foo.example.com/resource", "foo.example.com");
	test("foo.example.com/some resource", "foo.example.com");
	test("foo.example.com/some@resource", "foo.example.com");

	test("foo@foo.example.com/some@resource", "foo.example.com");
	test("foo@example/some@resource", "example");

	test("foo@example/@resource", "example");
	test("foo@example@resource", nil);
	test("foo@example", "example");
	test("foo", "foo");

	test(nil, nil);
end

function resource(resource)
	local function test(jid, expected_resource)
		assert_equal(resource(jid), expected_resource, "Unexpected resource for "..tostring(jid));
	end

	test("example.com", nil);
	test("foo.example.com", nil);
	test("foo.example.com/resource", "resource");
	test("foo.example.com/some resource", "some resource");
	test("foo.example.com/some@resource", "some@resource");

	test("foo@foo.example.com/some@resource", "some@resource");
	test("foo@example/some@resource", "some@resource");

	test("foo@example/@resource", "@resource");
	test("foo@example@resource", nil);
	test("foo@example", nil);
	test("foo", nil);
	test("/foo", nil);
	test("@x/foo", nil);
	test("@/foo", nil);

	test(nil, nil);
end

