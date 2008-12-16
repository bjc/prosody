-- Prosody IM v0.2
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



function core_process_stanza(core_process_stanza)
	local s2sout_session = { to_host = "remotehost", from_host = "localhost", type = "s2sout" }
	local s2sin_session = { from_host = "remotehost", to_host = "localhost", type = "s2sin" }
	local local_host_session = { host = "localhost", type = "local" }
	local local_user_session = { username = "user", host = "localhost", resource = "resource", full_jid = "user@localhost/resource", type = "c2s" }
	local hosts = {
			["localhost"] = local_host_session;
			}
				
	-- Test message routing
	local function test_message_full_jid()
		local env = testlib_new_env();
		local msg = stanza.stanza("message", { to = "user@localhost/resource", type = "chat" }):tag("body"):text("Hello world");
		
		local target_routed;
		
		function env.core_route_stanza(p_origin, p_stanza)
			assert_equal(p_origin, local_user_session, "origin of routed stanza is not correct");
			assert_equal(p_stanza, msg, "routed stanza is not correct one: "..p_stanza:pretty_print());
			target_routed = true;
		end
		env.hosts = hosts;
		setfenv(core_process_stanza, env);
		assert_equal(core_process_stanza(local_user_session, msg), nil, "core_process_stanza returned incorrect value");
		assert_equal(target_routed, true, "stanza was not routed successfully");
	end

	local function test_message_bare_jid()
		local env = testlib_new_env();
		local msg = stanza.stanza("message", { to = "user@localhost", type = "chat" }):tag("body"):text("Hello world");
		
		local target_routed;
		
		function env.core_route_stanza(p_origin, p_stanza)
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
		
		function env.core_route_stanza(p_origin, p_stanza)
		end

		function env.core_handle_stanza(p_origin, p_stanza)
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

		env.hosts = hosts;
		setfenv(core_process_stanza, env);
		assert_equal(core_process_stanza(local_user_session, msg), nil, "core_process_stanza returned incorrect value");
		assert_equal(target_routed, true, "stanza was not routed successfully");
	end

	--IQ tests


	local function test_iq_to_remote_server()
		local env = testlib_new_env();
		local msg = stanza.stanza("iq", { to = "remotehost", type = "chat" }):tag("body"):text("Hello world");
		
		local target_routed;
		
		function env.core_route_stanza(p_origin, p_stanza)
			assert_equal(p_origin, local_user_session, "origin of handled stanza is not correct");
			assert_equal(p_stanza, msg, "handled stanza is not correct one: "..p_stanza:pretty_print());
			target_routed = true;		
		end

		function env.core_handle_stanza(p_origin, p_stanza)
			
		end

		env.hosts = hosts;
		setfenv(core_process_stanza, env);
		assert_equal(core_process_stanza(local_user_session, msg), nil, "core_process_stanza returned incorrect value");
		assert_equal(target_routed, true, "stanza was not routed successfully");
	end

	local function test_iq_error_to_local_user()
		local env = testlib_new_env();
		local msg = stanza.stanza("iq", { to = "user@localhost/resource", from = "user@remotehost", type = "error" }):tag("error", { type = 'cancel' }):tag("item-not-found", { xmlns='urn:ietf:params:xml:ns:xmpp-stanzas' });
		
		local target_routed;
		
		function env.core_route_stanza(p_origin, p_stanza)
			assert_equal(p_origin, s2sin_session, "origin of handled stanza is not correct");
			assert_equal(p_stanza, msg, "handled stanza is not correct one: "..p_stanza:pretty_print());
			target_routed = true;		
		end

		function env.core_handle_stanza(p_origin, p_stanza)
			
		end

		env.hosts = hosts;
		setfenv(core_process_stanza, env);
		assert_equal(core_process_stanza(s2sin_session, msg), nil, "core_process_stanza returned incorrect value");
		assert_equal(target_routed, true, "stanza was not routed successfully");
	end

	runtest(test_message_full_jid, "Messages with full JID destinations get routed");
	runtest(test_message_bare_jid, "Messages with bare JID destinations get routed");
	runtest(test_message_no_to, "Messages with no destination are handled by the server");
	runtest(test_message_to_remote_bare, "Messages to a remote user are routed by the server");
	runtest(test_message_to_remote_server, "Messages to a remote server's JID are routed");

	runtest(test_iq_to_remote_server, "iq to a remote server's JID are routed");
	runtest(test_iq_error_to_local_user, "iq type=error to a local user's JID are routed");

end
