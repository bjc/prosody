
local st = require "util.stanza";
local send = require "core.sessionmanager".send_to_session;
local sm_bind_resource = require "core.sessionmanager".bind_resource;

local usermanager_validate_credentials = require "core.usermanager".validate_credentials;
local t_concat, t_insert = table.concat, table.insert;
local tostring = tostring;

local log = require "util.logger".init("mod_starttls");

local xmlns_starttls ='urn:ietf:params:xml:ns:xmpp-tls';

local new_connhandler = require "net.connhandlers".new;

add_handler("c2s_unauthed", "starttls", xmlns_starttls,
		function (session, stanza)
			if session.conn.starttls then
				print("Wants to do TLS...");
				send(session, st.stanza("proceed", { xmlns = xmlns_starttls }));
				session.connhandler = new_connhandler("xmpp-client", session);
				session.notopen = true;
				if session.conn.starttls() then
					print("Done");
				else
					print("Failed");
				end
				
			end
		end);
		
add_event_hook("stream-features", 
					function (session, features)												
						if session.conn.starttls then
							t_insert(features, "<starttls xmlns='"..xmlns_starttls.."'/>");
						end
					end);