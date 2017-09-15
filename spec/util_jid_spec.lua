
local jid = require "util.jid";

describe("util.jid", function()
	describe("#join()", function()
		it("should work", function()
			assert.are.equal(jid.join("a", "b", "c"), "a@b/c", "builds full JID");
			assert.are.equal(jid.join("a", "b", nil), "a@b", "builds bare JID");
			assert.are.equal(jid.join(nil, "b", "c"), "b/c", "builds full host JID");
			assert.are.equal(jid.join(nil, "b", nil), "b", "builds bare host JID");
			assert.are.equal(jid.join(nil, nil, nil), nil, "invalid JID is nil");
			assert.are.equal(jid.join("a", nil, nil), nil, "invalid JID is nil");
			assert.are.equal(jid.join(nil, nil, "c"), nil, "invalid JID is nil");
			assert.are.equal(jid.join("a", nil, "c"), nil, "invalid JID is nil");
		end);
	end);
	describe("#split()", function()
		it("should work", function()
			local function test(input_jid, expected_node, expected_server, expected_resource)
				local rnode, rserver, rresource = jid.split(input_jid);
				assert.are.equal(expected_node, rnode, "split("..tostring(input_jid)..") failed");
				assert.are.equal(expected_server, rserver, "split("..tostring(input_jid)..") failed");
				assert.are.equal(expected_resource, rresource, "split("..tostring(input_jid)..") failed");
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
		end);
	end);


	describe("#bare()", function()
		it("should work", function()
			assert.are.equal(jid.bare("user@host"), "user@host", "bare JID remains bare");
			assert.are.equal(jid.bare("host"), "host", "Host JID remains host");
			assert.are.equal(jid.bare("host/resource"), "host", "Host JID with resource becomes host");
			assert.are.equal(jid.bare("user@host/resource"), "user@host", "user@host JID with resource becomes user@host");
			assert.are.equal(jid.bare("user@/resource"), nil, "invalid JID is nil");
			assert.are.equal(jid.bare("@/resource"), nil, "invalid JID is nil");
			assert.are.equal(jid.bare("@/"), nil, "invalid JID is nil");
			assert.are.equal(jid.bare("/"), nil, "invalid JID is nil");
			assert.are.equal(jid.bare(""), nil, "invalid JID is nil");
			assert.are.equal(jid.bare("@"), nil, "invalid JID is nil");
			assert.are.equal(jid.bare("user@"), nil, "invalid JID is nil");
			assert.are.equal(jid.bare("user@@"), nil, "invalid JID is nil");
			assert.are.equal(jid.bare("user@@host"), nil, "invalid JID is nil");
			assert.are.equal(jid.bare("user@@host/resource"), nil, "invalid JID is nil");
			assert.are.equal(jid.bare("user@host/"), nil, "invalid JID is nil");
		end);
	end);

	describe("#compare()", function()
		it("should work", function()
			assert.are.equal(jid.compare("host", "host"), true, "host should match");
			assert.are.equal(jid.compare("host", "other-host"), false, "host should not match");
			assert.are.equal(jid.compare("other-user@host/resource", "host"), true, "host should match");
			assert.are.equal(jid.compare("other-user@host", "user@host"), false, "user should not match");
			assert.are.equal(jid.compare("user@host", "host"), true, "host should match");
			assert.are.equal(jid.compare("user@host/resource", "host"), true, "host should match");
			assert.are.equal(jid.compare("user@host/resource", "user@host"), true, "user and host should match");
			assert.are.equal(jid.compare("user@other-host", "host"), false, "host should not match");
			assert.are.equal(jid.compare("user@other-host", "user@host"), false, "host should not match");
		end);
	end);

	it("should work with nodes", function()
		local function test(_jid, expected_node)
			assert.are.equal(jid.node(_jid), expected_node, "Unexpected node for "..tostring(_jid));
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
	end);

	it("should work with hosts", function()
		local function test(_jid, expected_host)
			assert.are.equal(jid.host(_jid), expected_host, "Unexpected host for "..tostring(_jid));
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
	end);

	it("should work with resources", function()
		local function test(_jid, expected_resource)
			assert.are.equal(jid.resource(_jid), expected_resource, "Unexpected resource for "..tostring(_jid));
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
	end);
end);
