
-- Requires a host 'localhost' with SASL ANONYMOUS

local bosh_url = "http://localhost:5280/http-bind"

local logger = require "util.logger";

local debug = false;

local print = print;
if debug then
	logger.add_simple_sink(print, {
		--"debug";
		"info";
		"warn";
		"error";
	});
else
	print = function () end
end

describe("#mod_bosh", function ()
	local server = require "net.server_select";
	package.loaded["net.server"] = server;
	local async = require "util.async";
	local timer = require "util.timer";
	local http = require "net.http".new({ suppress_errors = false });

	local function sleep(n)
		local wait, done = async.waiter();
		timer.add_task(n, function () done() end);
		wait();
	end

	local st = require "util.stanza";
	local xml = require "util.xml";

	local function request(url, opt, cb, auto_wait)
		local wait, done = async.waiter();
		local ok, err;
		http:request(url, opt, function (...)
			ok, err = pcall(cb, ...);
			if not ok then print("CAUGHT", err) end
			done();
		end);
		local function err_wait(throw)
			wait();
			if throw ~= false and not ok then
				error(err);
			end
			return ok, err;
		end
		if auto_wait == false then
			return err_wait;
		else
			err_wait();
		end
	end

	local function run_async(f)
		local err;
		local r = async.runner();
		r:onerror(function (_, err_)
			print("EER", err_)
			err = err_;
			server.setquitting("once");
		end)
		:onwaiting(function ()
			--server.loop();
		end)
		:run(function ()
			f()
			server.setquitting("once");
		end);
		server.loop();
		if err then
			error(err);
		end
		if r.state ~= "ready" then
			error("Runner in unexpected state: "..r.state);
		end
	end

	it("test endpoint should be reachable", function ()
		-- This is partly just to ensure the other tests have a chance to succeed
		-- (i.e. the BOSH endpoint is up and functioning)
		local function test()
			request(bosh_url, nil, function (resp, code)
				if code ~= 200 then
					error("Unable to reach BOSH endpoint "..bosh_url);
				end
				assert.is_string(resp);
			end);
		end
		run_async(test);
	end);

	it("should respond to past rids with past responses", function ()
		local resp_1000_1, resp_1000_2 = "1", "2";

		local function test_bosh()
			local sid;

		-- Set up BOSH session
			request(bosh_url, {
				body = tostring(st.stanza("body", {
					to = "localhost";
					from = "test@localhost";
					content = "text/xml; charset=utf-8";
					hold = "1";
					rid = "998";
					wait = "10";
					["xml:lang"] = "en";
					["xmpp:version"] = "1.0";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				})
				:tag("auth", { xmlns = "urn:ietf:params:xml:ns:xmpp-sasl", mechanism = "ANONYMOUS" }):up()
				:tag("iq", { xmlns = "jabber:client", type = "set", id = "bind1" })
					:tag("bind", { xmlns = "urn:ietf:params:xml:ns:xmpp-bind" })
						:tag("resource"):text("bosh-test1"):up()
					:up()
				:up()
				);
			}, function (response_body)
				local resp = xml.parse(response_body);
				if not response_body:find("<jid>", 1, true) then
					print("ERR", resp:pretty_print());
					error("Failed to set up BOSH session");
				end
				sid = assert(resp.attr.sid);
				print("SID", sid);
			end);

		-- Receive some additional post-login stuff
			request(bosh_url, {
				body = tostring(st.stanza("body", {
					sid = sid;
					rid = "999";
					content = "text/xml; charset=utf-8";
					["xml:lang"] = "en";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				})
				)
			}, function (response_body)
				local resp = xml.parse(response_body);
				print("RESP 999", resp:pretty_print());
			end);

		-- Send first long poll
			print "SEND 1000#1"
			local wait1000 = request(bosh_url, {
				body = tostring(st.stanza("body", {
					sid = sid;
					rid = "1000";
					content = "text/xml; charset=utf-8";
					["xml:lang"] = "en";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				}))
			}, function (response_body)
				local resp = xml.parse(response_body);
				resp_1000_1 = resp;
				print("RESP 1000#1", resp:pretty_print());
			end, false);

		-- Wait a couple of seconds
			sleep(2)

		-- Send an early request, causing rid 1000 to return early
			print "SEND 1001"
			local wait1001 = request(bosh_url, {
				body = tostring(st.stanza("body", {
					sid = sid;
					rid = "1001";
					content = "text/xml; charset=utf-8";
					["xml:lang"] = "en";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				}))
			}, function (response_body)
				local resp = xml.parse(response_body);
				print("RESP 1001", resp:pretty_print());
			end, false);
		-- Ensure we've received the response for rid 1000
			wait1000();

		-- Sleep a couple of seconds
			print "...pause..."
			sleep(2);

		-- Re-send rid 1000, we should get the same response
			print "SEND 1000#2"
			request(bosh_url, {
				body = tostring(st.stanza("body", {
					sid = sid;
					rid = "1000";
					content = "text/xml; charset=utf-8";
					["xml:lang"] = "en";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				}))
			}, function (response_body)
				local resp = xml.parse(response_body);
				resp_1000_2 = resp;
				print("RESP 1000#2", resp:pretty_print());
			end);

			local wait_final = request(bosh_url, {
				body = tostring(st.stanza("body", {
					sid = sid;
					rid = "1002";
					type = "terminate";
					content = "text/xml; charset=utf-8";
					["xml:lang"] = "en";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				}))
			}, function ()
			end, false);

			print "WAIT 1001"
			wait1001();
			wait_final();
			print "DONE ALL"
		end
		run_async(test_bosh);
		assert.truthy(resp_1000_1);
		assert.same(resp_1000_1, resp_1000_2);
	end);

	it("should handle out-of-order requests", function ()
		local function test()
			local sid;
		-- Set up BOSH session
			local wait, done = async.waiter();
			http:request(bosh_url, {
				body = tostring(st.stanza("body", {
					to = "localhost";
					from = "test@localhost";
					content = "text/xml; charset=utf-8";
					hold = "1";
					rid = "1";
					wait = "10";
					["xml:lang"] = "en";
					["xmpp:version"] = "1.0";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				}));
			}, function (response_body)
				local resp = xml.parse(response_body);
				sid = assert(resp.attr.sid, "Failed to set up BOSH session");
				print("SID", sid);
				done();
			end);
			print "WAIT 1"
			wait();
			print "DONE 1"

			local rid2_response_received = false;

		-- Temporarily skip rid 2, to simulate missed request
			local wait3, done3 = async.waiter();
			http:request(bosh_url, {
				body = tostring(st.stanza("body", {
					sid = sid;
					rid = "3";
					content = "text/xml; charset=utf-8";
					["xml:lang"] = "en";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				}):tag("iq", { xmlns = "jabber:client", type = "set", id = "bind" })
					:tag("bind", { xmlns = "urn:ietf:params:xml:ns:xmpp-bind" }):up()
				:up()
				)
			}, function (response_body)
				local resp = xml.parse(response_body);
				print("RESP 3", resp:pretty_print());
				done3();
				-- The server should not respond to this request until
				-- it has responded to rid 2
				assert.is_true(rid2_response_received);
			end);

			print "SLEEPING"
			sleep(2);
			print "SLEPT"

		-- Send the "missed" rid 2
			local wait2, done2 = async.waiter();
			http:request(bosh_url, {
				body = tostring(st.stanza("body", {
					sid = sid;
					rid = "2";
					content = "text/xml; charset=utf-8";
					["xml:lang"] = "en";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				}):tag("auth", { xmlns = "urn:ietf:params:xml:ns:xmpp-sasl", mechanism = "ANONYMOUS" }):up()
				)
			}, function (response_body)
				local resp = xml.parse(response_body);
				print("RESP 2", resp:pretty_print());
				rid2_response_received = true;
				done2();
			end);
			print "WAIT 2"
			wait2();
			print "WAIT 3"
			wait3();
			print "QUIT"
		end
		run_async(test);
	end);

	it("should work", function ()
		local function test()
			local sid;
		-- Set up BOSH session
			local wait, done = async.waiter();
			http:request(bosh_url, {
				body = tostring(st.stanza("body", {
					to = "localhost";
					from = "test@localhost";
					content = "text/xml; charset=utf-8";
					hold = "1";
					rid = "1";
					wait = "10";
					["xml:lang"] = "en";
					["xmpp:version"] = "1.0";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				}));
			}, function (response_body)
				local resp = xml.parse(response_body);
				sid = assert(resp.attr.sid, "Failed to set up BOSH session");
				print("SID", sid);
				done();
			end);
			print "WAIT 1"
			wait();
			print "DONE 1"

			local rid2_response_received = false;

		-- Send the "missed" rid 2
			local wait2, done2 = async.waiter();
			http:request(bosh_url, {
				body = tostring(st.stanza("body", {
					sid = sid;
					rid = "2";
					content = "text/xml; charset=utf-8";
					["xml:lang"] = "en";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				}):tag("auth", { xmlns = "urn:ietf:params:xml:ns:xmpp-sasl", mechanism = "ANONYMOUS" }):up()
				)
			}, function (response_body)
				local resp = xml.parse(response_body);
				print("RESP 2", resp:pretty_print());
				rid2_response_received = true;
				done2();
			end);

			local wait3, done3 = async.waiter();
			http:request(bosh_url, {
				body = tostring(st.stanza("body", {
					sid = sid;
					rid = "3";
					content = "text/xml; charset=utf-8";
					["xml:lang"] = "en";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				}):tag("iq", { xmlns = "jabber:client", type = "set", id = "bind" })
					:tag("bind", { xmlns = "urn:ietf:params:xml:ns:xmpp-bind" }):up()
				:up()
				)
			}, function (response_body)
				local resp = xml.parse(response_body);
				print("RESP 3", resp:pretty_print());
				done3();
				-- The server should not respond to this request until
				-- it has responded to rid 2
				assert.is_true(rid2_response_received);
			end);

			print "SLEEPING"
			sleep(2);
			print "SLEPT"

			print "WAIT 2"
			wait2();
			print "WAIT 3"
			wait3();
			print "QUIT"
		end
		run_async(test);
	end);

	it("should handle aborted pending requests", function ()
		local resp_1000_1, resp_1000_2 = "1", "2";

		local function test_bosh()
			local sid;

		-- Set up BOSH session
			request(bosh_url, {
				body = tostring(st.stanza("body", {
					to = "localhost";
					from = "test@localhost";
					content = "text/xml; charset=utf-8";
					hold = "1";
					rid = "998";
					wait = "10";
					["xml:lang"] = "en";
					["xmpp:version"] = "1.0";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				})
				:tag("auth", { xmlns = "urn:ietf:params:xml:ns:xmpp-sasl", mechanism = "ANONYMOUS" }):up()
				:tag("iq", { xmlns = "jabber:client", type = "set", id = "bind1" })
					:tag("bind", { xmlns = "urn:ietf:params:xml:ns:xmpp-bind" })
						:tag("resource"):text("bosh-test1"):up()
					:up()
				:up()
				);
			}, function (response_body)
				local resp = xml.parse(response_body);
				if not response_body:find("<jid>", 1, true) then
					print("ERR", resp:pretty_print());
					error("Failed to set up BOSH session");
				end
				sid = assert(resp.attr.sid);
				print("SID", sid);
			end);

		-- Receive some additional post-login stuff
			request(bosh_url, {
				body = tostring(st.stanza("body", {
					sid = sid;
					rid = "999";
					content = "text/xml; charset=utf-8";
					["xml:lang"] = "en";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				})
				)
			}, function (response_body)
				local resp = xml.parse(response_body);
				print("RESP 999", resp:pretty_print());
			end);

		-- Send first long poll
			print "SEND 1000#1"
			local wait1000_1 = request(bosh_url, {
				body = tostring(st.stanza("body", {
					sid = sid;
					rid = "1000";
					content = "text/xml; charset=utf-8";
					["xml:lang"] = "en";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				}))
			}, function (response_body)
				local resp = xml.parse(response_body);
				resp_1000_1 = resp;
				assert.is_nil(resp.attr.type);
				print("RESP 1000#1", resp:pretty_print());
			end, false);

		-- Wait a couple of seconds
			sleep(2)

		-- Re-send rid 1000, we should eventually get a normal response (with no stanzas)
			print "SEND 1000#2"
			request(bosh_url, {
				body = tostring(st.stanza("body", {
					sid = sid;
					rid = "1000";
					content = "text/xml; charset=utf-8";
					["xml:lang"] = "en";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				}))
			}, function (response_body)
				local resp = xml.parse(response_body);
				resp_1000_2 = resp;
				assert.is_nil(resp.attr.type);
				print("RESP 1000#2", resp:pretty_print());
			end);

			wait1000_1();
			print "DONE ALL"
		end
		run_async(test_bosh);
		assert.truthy(resp_1000_1);
		assert.same(resp_1000_1, resp_1000_2);
	end);

	it("should fail on requests beyond rid window", function ()
		local function test_bosh()
			local sid;

		-- Set up BOSH session
			request(bosh_url, {
				body = tostring(st.stanza("body", {
					to = "localhost";
					from = "test@localhost";
					content = "text/xml; charset=utf-8";
					hold = "1";
					rid = "998";
					wait = "10";
					["xml:lang"] = "en";
					["xmpp:version"] = "1.0";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				})
				:tag("auth", { xmlns = "urn:ietf:params:xml:ns:xmpp-sasl", mechanism = "ANONYMOUS" }):up()
				:tag("iq", { xmlns = "jabber:client", type = "set", id = "bind1" })
					:tag("bind", { xmlns = "urn:ietf:params:xml:ns:xmpp-bind" })
						:tag("resource"):text("bosh-test1"):up()
					:up()
				:up()
				);
			}, function (response_body)
				local resp = xml.parse(response_body);
				if not response_body:find("<jid>", 1, true) then
					print("ERR", resp:pretty_print());
					error("Failed to set up BOSH session");
				end
				sid = assert(resp.attr.sid);
				print("SID", sid);
			end);

		-- Receive some additional post-login stuff
			request(bosh_url, {
				body = tostring(st.stanza("body", {
					sid = sid;
					rid = "999";
					content = "text/xml; charset=utf-8";
					["xml:lang"] = "en";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				})
				)
			}, function (response_body)
				local resp = xml.parse(response_body);
				print("RESP 999", resp:pretty_print());
			end);

		-- Send poll with a rid that's too high (current + 2, where only current + 1 is allowed)
			print "SEND 1002(!)"
			request(bosh_url, {
				body = tostring(st.stanza("body", {
					sid = sid;
					rid = "1002";
					content = "text/xml; charset=utf-8";
					["xml:lang"] = "en";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				}))
			}, function (response_body)
				local resp = xml.parse(response_body);
				assert.equal("terminate", resp.attr.type);
				print("RESP 1002(!)", resp:pretty_print());
			end);

			print "DONE ALL"
		end
		run_async(test_bosh);
	end);

	it("should always succeed for requests within the rid window", function ()
		local function test()
			local sid;
		-- Set up BOSH session
			request(bosh_url, {
				body = tostring(st.stanza("body", {
					to = "localhost";
					from = "test@localhost";
					content = "text/xml; charset=utf-8";
					hold = "1";
					rid = "1";
					wait = "10";
					["xml:lang"] = "en";
					["xmpp:version"] = "1.0";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				}));
			}, function (response_body)
				local resp = xml.parse(response_body);
				sid = assert(resp.attr.sid, "Failed to set up BOSH session");
				print("SID", sid);
			end);
			print "DONE 1"

			request(bosh_url, {
				body = tostring(st.stanza("body", {
					sid = sid;
					rid = "2";
					content = "text/xml; charset=utf-8";
					["xml:lang"] = "en";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				}):tag("auth", { xmlns = "urn:ietf:params:xml:ns:xmpp-sasl", mechanism = "ANONYMOUS" }):up()
				)
			}, function (response_body)
				local resp = xml.parse(response_body);
				print("RESP 2", resp:pretty_print());
			end);

			local resp3;
			request(bosh_url, {
				body = tostring(st.stanza("body", {
					sid = sid;
					rid = "3";
					content = "text/xml; charset=utf-8";
					["xml:lang"] = "en";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				}):tag("iq", { xmlns = "jabber:client", type = "set", id = "bind" })
					:tag("bind", { xmlns = "urn:ietf:params:xml:ns:xmpp-bind" }):up()
				:up()
				)
			}, function (response_body)
				local resp = xml.parse(response_body);
				print("RESP 3#1", resp:pretty_print());
				resp3 = resp;
			end);


			request(bosh_url, {
				body = tostring(st.stanza("body", {
					sid = sid;
					rid = "4";
					content = "text/xml; charset=utf-8";
					["xml:lang"] = "en";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				}):tag("iq", { xmlns = "jabber:client", type = "get", id = "ping1" })
					:tag("ping", { xmlns = "urn:xmpp:ping" }):up()
				:up()
				)
			}, function (response_body)
				local resp = xml.parse(response_body);
				print("RESP 4", resp:pretty_print());
			end);

			request(bosh_url, {
				body = tostring(st.stanza("body", {
					sid = sid;
					rid = "3";
					content = "text/xml; charset=utf-8";
					["xml:lang"] = "en";
					xmlns = "http://jabber.org/protocol/httpbind";
					["xmlns:xmpp"] = "urn:xmpp:xbosh";
				}):tag("iq", { xmlns = "jabber:client", type = "set", id = "bind" })
					:tag("bind", { xmlns = "urn:ietf:params:xml:ns:xmpp-bind" }):up()
				:up()
				)
			}, function (response_body)
				local resp = xml.parse(response_body);
				print("RESP 3#2", resp:pretty_print());
				assert.not_equal("terminate", resp.attr.type);
				assert.same(resp3, resp);
			end);


			print "QUIT"
		end
		run_async(test);
	end);
end);
