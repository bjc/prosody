
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
end
