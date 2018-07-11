
local xmppstream = require "util.xmppstream";

describe("util.xmppstream", function()
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
		local stream = xmppstream.new(session, callbacks, ex and ex._size_limit or nil);
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

	describe("#new()", function()
		it("should work", function()
			test([[<stream:stream xmlns:stream="streamns"/>]], true);
			test([[<stream xmlns="streamns"/>]], true);

			-- Incorrect stream tag name should be rejected
			test([[<stream1 xmlns="streamns"/>]], false);
			-- Incorrect stream namespace should be rejected
			test([[<stream xmlns="streamns1"/>]], false);
			-- Invalid XML should be rejected
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

	it("should allow an XML declaration", function ()
		test([[<?xml version="1.0" encoding="UTF-8"?><stream xmlns="streamns"/>]], true);
		test([[<?xml version="1.0" encoding="UTF-8" standalone="yes" ?><stream xmlns="streamns"/>]], true);
		test([[<?xml version="1.0" encoding="utf-8" ?><stream xmlns="streamns"/>]], true);
	end);

	it("should not accept XML versions other than 1.0", function ()
		test([[<?xml version="1.1" encoding="utf-8" ?><stream xmlns="streamns"/>]], false);
	end);

	it("should not allow a misplaced XML declaration", function ()
		test([[<stream xmlns="streamns"><?xml version="1.0" encoding="UTF-8"?></stream>]], false);
	end);

	describe("should forbid restricted XML:", function ()
		it("comments", function ()
			test_stanza("<!-- hello world -->", false);
		end);
		it("DOCTYPE", function ()
			test([[<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE stream SYSTEM "mydtd.dtd">]], false);
		end);
		it("incorrect encoding specification", function ()
			-- This is actually caught by the underlying XML parser
			test([[<?xml version="1.0" encoding="UTF-16"?><stream xmlns="streamns"/>]], false);
		end);
		it("non-UTF8 encodings: ISO-8859-1", function ()
			test([[<?xml version="1.0" encoding="ISO-8859-1"?><stream xmlns="streamns"/>]], false);
		end);
		it("non-UTF8 encodings: UTF-16", function ()
			-- <?xml version="1.0" encoding="UTF-16"?><stream xmlns="streamns"/>
			-- encoded into UTF-16
			local hx = ([[fffe3c003f0078006d006c002000760065007200730069006f006e003d00
			220031002e0030002200200065006e0063006f00640069006e0067003d00
			22005500540046002d003100360022003f003e003c007300740072006500
			61006d00200078006d006c006e0073003d00220073007400720065006100
			6d006e00730022002f003e00]]):gsub("%x%x", function (c) return string.char(tonumber(c, 16)); end);
			test(hx, false);
		end);
		it("processing instructions", function ()
			test([[<stream xmlns="streamns"><?xml-stylesheet type="text/xsl" href="style.xsl"?></stream>]], false);
		end);
	end);
end);
