
function split(split)
	function test(jid, node, server, resource)
		local rnode, rserver, rresource = split(jid);
		assert_equal(node, rnode, "split("..jid..") failed");
		assert_equal(server, rserver, "split("..jid..") failed");
		assert_equal(resource, rresource, "split("..jid..") failed");
	end
	test("node@server", 		"node", "server", nil		);
	test("node@server/resource", 	"node", "server", "resource"	);
	test("server", 			nil, 	"server", nil		);
	test("server/resource", 	nil, 	"server", "resource"	);
end
