
local xmppstream = require "util.xmppstream";

describe("util.xmppstream", function()
	describe("#new()", function()
		it("should work", function()
			local function test(xml, expect_success, ex)
				local stanzas = {};
				local session = { notopen = true };
				local callbacks = {
					stream_ns = "streamns";
					stream_tag = "stream";
					default_ns = "stanzans";
					streamopened = function (_session)
						assert.are.equal(session, _session);
						assert.are.equal(session.notopen, true);
						_session.notopen = nil;
						return true;
					end;
					handlestanza = function (_session, stanza)
						assert.are.equal(session, _session);
						assert.are.equal(_session.notopen, nil);
						table.insert(stanzas, stanza);
					end;
					streamclosed = function (_session)
						assert.are.equal(session, _session);
						assert.are.equal(_session.notopen, nil);
						_session.notopen = nil;
					end;
				}
				if type(ex) == "table" then
					for k, v in pairs(ex) do
						if k ~= "_size_limit" then
							callbacks[k] = v;
						end
					end
				end
				local stream = xmppstream.new(session, callbacks, size_limit);
				local ok, err = pcall(function ()
					assert(stream:feed(xml));
				end);

				if ok and type(expect_success) == "function" then
					expect_success(stanzas);
				end
				assert.are.equal(not not ok, not not expect_success, "Expected "..(expect_success and ("success ("..tostring(err)..")") or "failure"));
			end

			local function test_stanza(stanza, expect_success, ex)
				return test([[<stream:stream xmlns:stream="streamns" xmlns="stanzans">]]..stanza, expect_success, ex);
			end

			test([[<stream:stream xmlns:stream="streamns"/>]], true);
			test([[<stream xmlns="streamns"/>]], true);

			test([[<stream1 xmlns="streamns"/>]], false);
			test([[<stream xmlns="streamns1"/>]], false);
			test("<>", false);

			test_stanza("<message/>", function (stanzas)
				assert.are.equal(#stanzas, 1);
				assert.are.equal(stanzas[1].name, "message");
			end);
			test_stanza("< message>>>>/>\n", false);

			test_stanza([[<x xmlns:a="b">
				<y xmlns:a="c">
					<a:z/>
				</y>
				<a:z/>
			</x>]], function (stanzas)
				assert.are.equal(#stanzas, 1);
				local s = stanzas[1];
				assert.are.equal(s.name, "x");
				assert.are.equal(#s.tags, 2);

				assert.are.equal(s.tags[1].name, "y");
				assert.are.equal(s.tags[1].attr.xmlns, nil);

				assert.are.equal(s.tags[1].tags[1].name, "z");
				assert.are.equal(s.tags[1].tags[1].attr.xmlns, "c");

				assert.are.equal(s.tags[2].name, "z");
				assert.are.equal(s.tags[2].attr.xmlns, "b");

				assert.are.equal(s.namespaces, nil);
			end);
		end);
	end);
end);
