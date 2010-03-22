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
	test("node@server", 		"node", "server", nil		);
	test("node@server/resource", 	"node", "server", "resource"	);
	test("server", 			nil, 	"server", nil		);
	test("server/resource", 	nil, 	"server", "resource"	);
	test(nil,			nil,	nil	, nil		);

	test("node@/server", nil, nil, nil , nil );
	test("@server",      nil, nil, nil , nil );
	test("@server/resource",nil,nil,nil, nil );
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

