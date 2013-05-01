-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

_G.prosody = { full_sessions = {}; bare_sessions = {}; hosts = {}; };

function core_process_stanza(core_process_stanza, u)
	local stanza = require "util.stanza";
	local s2sout_session = { to_host = "remotehost", from_host = "localhost", type = "s2sout" }
	local s2sin_session = { from_host = "remotehost", to_host = "localhost", type = "s2sin", hosts = { ["remotehost"] = { authed = true } } }
	local local_host_session = { host = "localhost", type = "local", s2sout = { ["remotehost"] = s2sout_session } }
	local local_user_session = { username = "user", host = "localhost", resource = "resource", full_jid = "user@localhost/resource", type = "c2s" }
	
	_G.prosody.hosts["localhost"] = local_host_session;
	_G.prosody.full_sessions["user@localhost/resource"] = local_user_session;
	_G.prosody.bare_sessions["user@localhost"] = { sessions = { resource = local_user_session } };

	-- Test message routing
	local function test_message_full_jid()
		local env = testlib_new_env();
		local msg = stanza.stanza("message", { to = "user@localhost/resource", type = "chat" }):tag("body"):text("Hello world");
		
		local target_routed;
		
		function env.core_post_stanza(p_origin, p_stanza)
			assert_equal(p_origin, local_user_session, "origin of routed stanza is not correct");
			assert_equal(p_stanza, msg, "routed stanza is not correct one: "..p_stanza:pretty_print());
			target_routed = true;
		end
		
		env.hosts = hosts;
		env.prosody = { hosts = hosts };
		setfenv(core_process_stanza, env);
		assert_equal(core_process_stanza(local_user_session, msg), nil, "core_process_stanza returned incorrect value");
		assert_equal(target_routed, true, "stanza was not routed successfully");
	end

	local function test_message_bare_jid()
		local env = testlib_new_env();
		local msg = stanza.stanza("message", { to = "user@localhost", type = "chat" }):tag("body"):text("Hello world");
		
		local target_routed;
		
		function env.core_post_stanza(p_origin, p_stanza)
			assert_equal(p_origin, local_user_session, "origin of routed stanza is not correct");
			assert_equal(p_stanza, msg, "routed stanza is not correct one: "..p_stanza:pretty_print());
			target_routed = true;
		end

		env.hosts = hosts;
		setfenv(core_process_stanza, env);
		assert_equal(core_process_stanza(local_user_session, msg), nil, "core_process_stanza returned incorrect value");
		assert_equal(target_routed, true, "stanza was not routed successfully");
	end

	local function test_message_no_to()
		local env = testlib_new_env();
		local msg = stanza.stanza("message", { type = "chat" }):tag("body"):text("Hello world");
		
		local target_handled;
		
		function env.core_post_stanza(p_origin, p_stanza)
			assert_equal(p_origin, local_user_session, "origin of handled stanza is not correct");
			assert_equal(p_stanza, msg, "handled stanza is not correct one: "..p_stanza:pretty_print());
			target_handled = true;
		end

		env.hosts = hosts;
		setfenv(core_process_stanza, env);
		assert_equal(core_process_stanza(local_user_session, msg), nil, "core_process_stanza returned incorrect value");
		assert_equal(target_handled, true, "stanza was not handled successfully");
	end

	local function test_message_to_remote_bare()
		local env = testlib_new_env();
		local msg = stanza.stanza("message", { to = "user@remotehost", type = "chat" }):tag("body"):text("Hello world");
		
		local target_routed;
		
		function env.core_route_stanza(p_origin, p_stanza)
			assert_equal(p_origin, local_user_session, "origin of handled stanza is not correct");
			assert_equal(p_stanza, msg, "handled stanza is not correct one: "..p_stanza:pretty_print());
			target_routed = true;
		end

		function env.core_post_stanza(...) env.core_route_stanza(...); end
		
		env.hosts = hosts;
		setfenv(core_process_stanza, env);
		assert_equal(core_process_stanza(local_user_session, msg), nil, "core_process_stanza returned incorrect value");
		assert_equal(target_routed, true, "stanza was not routed successfully");
	end

	local function test_message_to_remote_server()
		local env = testlib_new_env();
		local msg = stanza.stanza("message", { to = "remotehost", type = "chat" }):tag("body"):text("Hello world");
		
		local target_routed;
		
		function env.core_route_stanza(p_origin, p_stanza)
			assert_equal(p_origin, local_user_session, "origin of handled stanza is not correct");
			assert_equal(p_stanza, msg, "handled stanza is not correct one: "..p_stanza:pretty_print());
			target_routed = true;
		end

		function env.core_post_stanza(...)
			env.core_route_stanza(...);
		end

		env.hosts = hosts;
		setfenv(core_process_stanza, env);
		assert_equal(core_process_stanza(local_user_session, msg), nil, "core_process_stanza returned incorrect value");
		assert_equal(target_routed, true, "stanza was not routed successfully");
	end

	--IQ tests


	local function test_iq_to_remote_server()
		local env = testlib_new_env();
		local msg = stanza.stanza("iq", { to = "remotehost", type = "get", id = "id" }):tag("body"):text("Hello world");
		
		local target_routed;
		
		function env.core_route_stanza(p_origin, p_stanza)
			assert_equal(p_origin, local_user_session, "origin of handled stanza is not correct");
			assert_equal(p_stanza, msg, "handled stanza is not correct one: "..p_stanza:pretty_print());
			target_routed = true;
		end

		function env.core_post_stanza(...)
			env.core_route_stanza(...);
		end

		env.hosts = hosts;
		setfenv(core_process_stanza, env);
		assert_equal(core_process_stanza(local_user_session, msg), nil, "core_process_stanza returned incorrect value");
		assert_equal(target_routed, true, "stanza was not routed successfully");
	end

	local function test_iq_error_to_local_user()
		local env = testlib_new_env();
		local msg = stanza.stanza("iq", { to = "user@localhost/resource", from = "user@remotehost", type = "error", id = "id" }):tag("error", { type = 'cancel' }):tag("item-not-found", { xmlns='urn:ietf:params:xml:ns:xmpp-stanzas' });
		
		local target_routed;
		
		function env.core_route_stanza(p_origin, p_stanza)
			assert_equal(p_origin, s2sin_session, "origin of handled stanza is not correct");
			assert_equal(p_stanza, msg, "handled stanza is not correct one: "..p_stanza:pretty_print());
			target_routed = true;
		end

		function env.core_post_stanza(...)
			env.core_route_stanza(...);
		end

		env.hosts = hosts;
		setfenv(core_process_stanza, env);
		assert_equal(core_process_stanza(s2sin_session, msg), nil, "core_process_stanza returned incorrect value");
		assert_equal(target_routed, true, "stanza was not routed successfully");
	end

	local function test_iq_to_local_bare()
		local env = testlib_new_env();
		local msg = stanza.stanza("iq", { to = "user@localhost", from = "user@localhost", type = "get", id = "id" }):tag("ping", { xmlns = "urn:xmpp:ping:0" });
		
		local target_handled;
		
		function env.core_post_stanza(p_origin, p_stanza)
			assert_equal(p_origin, local_user_session, "origin of handled stanza is not correct");
			assert_equal(p_stanza, msg, "handled stanza is not correct one: "..p_stanza:pretty_print());
			target_handled = true;
		end

		env.hosts = hosts;
		setfenv(core_process_stanza, env);
		assert_equal(core_process_stanza(local_user_session, msg), nil, "core_process_stanza returned incorrect value");
		assert_equal(target_handled, true, "stanza was not handled successfully");
	end

	runtest(test_message_full_jid, "Messages with full JID destinations get routed");
	runtest(test_message_bare_jid, "Messages with bare JID destinations get routed");
	runtest(test_message_no_to, "Messages with no destination are handled by the server");
	runtest(test_message_to_remote_bare, "Messages to a remote user are routed by the server");
	runtest(test_message_to_remote_server, "Messages to a remote server's JID are routed");

	runtest(test_iq_to_remote_server, "iq to a remote server's JID are routed");
	runtest(test_iq_to_local_bare, "iq from a local user to a local user's bare JID are handled");
	runtest(test_iq_error_to_local_user, "iq type=error to a local user's JID are routed");
end

function core_route_stanza(core_route_stanza)
	local stanza = require "util.stanza";
	local s2sout_session = { to_host = "remotehost", from_host = "localhost", type = "s2sout" }
	local s2sin_session = { from_host = "remotehost", to_host = "localhost", type = "s2sin", hosts = { ["remotehost"] = { authed = true } } }
	local local_host_session = { host = "localhost", type = "local", s2sout = { ["remotehost"] = s2sout_session }, sessions = {} }
	local local_user_session = { username = "user", host = "localhost", resource = "resource", full_jid = "user@localhost/resource", type = "c2s" }
	local hosts = {
			["localhost"] = local_host_session;
			}

	local function test_iq_result_to_offline_user()
		local env = testlib_new_env();
		local msg = stanza.stanza("iq", { to = "user@localhost/foo", from = "user@localhost", type = "result" }):tag("ping", { xmlns = "urn:xmpp:ping:0" });
		local msg2 = stanza.stanza("iq", { to = "user@localhost/foo", from = "user@localhost", type = "error" }):tag("ping", { xmlns = "urn:xmpp:ping:0" });
		--package.loaded["core.usermanager"] = { user_exists = function (user, host) print("RAR!") return true or user == "user" and host == "localhost" and true; end };
		local target_handled, target_replied;
		
		function env.core_post_stanza(p_origin, p_stanza)
			target_handled = true;
		end
		
		function local_user_session.send(data)
			--print("Replying with: ", tostring(data));
			--print(debug.traceback())
			target_replied = true;
		end

		env.hosts = hosts;
		setfenv(core_route_stanza, env);
		assert_equal(core_route_stanza(local_user_session, msg), nil, "core_route_stanza returned incorrect value");
		assert_equal(target_handled, nil, "stanza was handled and not dropped");
		assert_equal(target_replied, nil, "stanza was replied to and not dropped");
		package.loaded["core.usermanager"] = nil;
	end

	--runtest(test_iq_result_to_offline_user, "iq type=result|error to an offline user are not replied to");
end
