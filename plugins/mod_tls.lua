
local st = require "util.stanza";
local send = require "core.sessionmanager".send_to_session;
local sm_bind_resource = require "core.sessionmanager".bind_resource;

local sessions = sessions;

local usermanager_validate_credentials = require "core.usermanager".validate_credentials;
local t_concat, t_insert = table.concat, table.insert;
local tostring = tostring;

local log = require "util.logger".init("mod_starttls");

local xmlns_starttls ='urn:ietf:params:xml:ns:xmpp-tls';

local new_connhandler = require "net.connhandlers".new;

add_handler("c2s_unauthed", "starttls", xmlns_starttls,
		function (session, stanza)
			if session.conn.starttls then
				send(session, st.stanza("proceed", { xmlns = xmlns_starttls }));
				-- FIXME: I'm commenting the below, not sure why it was necessary
				-- sessions[session.conn] = nil;
				session:reset_stream();
				session.conn.starttls();
				session.log("info", "TLS negotiation started...");
			else
				-- FIXME: What reply?
				session.log("warn", "Attempt to start TLS, but TLS is not available on this connection");
			end
		end);
		
add_event_hook("stream-features", 
					function (session, features)												
						if session.conn.starttls then
							t_insert(features, "<starttls xmlns='"..xmlns_starttls.."'/>");
						end
					end);