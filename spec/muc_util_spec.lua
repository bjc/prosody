local muc_util;

local st = require "util.stanza";

do
	local old_pp = package.path;
	package.path = "./?.lib.lua;"..package.path;
	muc_util = require "plugins.muc.util";
	package.path = old_pp;
end

describe("muc/util", function ()
	describe("filter_muc_x()", function ()
		it("correctly filters muc#user", function ()
			local stanza = st.message({ to = "to", from = "from", id = "foo" })
				:tag("x", { xmlns = "http://jabber.org/protocol/muc#user" })
					:tag("invite", { to = "user@example.com" });

			assert.equal(1, #stanza.tags);
			assert.equal(stanza, muc_util.filter_muc_x(stanza));
			assert.equal(0, #stanza.tags);
		end);

		it("correctly filters muc#user on a cloned stanza", function ()
			local stanza = st.message({ to = "to", from = "from", id = "foo" })
				:tag("x", { xmlns = "http://jabber.org/protocol/muc#user" })
					:tag("invite", { to = "user@example.com" });

			assert.equal(1, #stanza.tags);
			local filtered = muc_util.filter_muc_x(st.clone(stanza));
			assert.equal(1, #stanza.tags);
			assert.equal(0, #filtered.tags);
		end);
	end);
end);
