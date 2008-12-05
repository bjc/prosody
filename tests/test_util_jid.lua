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
