
local st = require "util.stanza";
local send = require "core.sessionmanager".send_to_session;
local sm_bind_resource = require "core.sessionmanager".bind_resource;

local usermanager_validate_credentials = require "core.usermanager".validate_credentials;
local t_concat, t_insert = table.concat, table.insert;
local tostring = tostring;

local log = require "util.logger".init("mod_saslauth");

local xmlns_sasl ='urn:ietf:params:xml:ns:xmpp-sasl';
local xmlns_bind ='urn:ietf:params:xml:ns:xmpp-bind';
local xmlns_stanzas ='urn:ietf:params:xml:ns:xmpp-stanzas';

local new_connhandler = require "net.connhandlers".new;
local new_sasl = require "util.sasl".new;

add_handler("c2s_unauthed", "auth", xmlns_sasl,
		function (session, stanza)
			if not session.sasl_handler then
				session.sasl_handler = new_sasl(stanza.attr.mechanism, 
					function (username, password)
						-- onAuth
						require "core.usermanager"
						if usermanager_validate_credentials(session.host, username, password) then
							return true;
						end
						return false;
					end,
					function (username)
						-- onSuccess
						local success, err = sessionmanager.make_authenticated(session, username);
						if not success then
							sessionmanager.destroy_session(session);
						end
						session.sasl_handler = nil;
						session.connhandler = new_connhandler("xmpp-client", session);
						session.notopen = true;
					end,
					function (reason)
						-- onFail
						log("debug", "SASL failure, reason: %s", reason);
					end,
					function (stanza)
						-- onWrite
						log("debug", "SASL writes: %s", tostring(stanza));
						send(session, stanza);
					end
				);
				session.sasl_handler:feed(stanza);	
			else
				error("Client tried to negotiate SASL again", 0);
			end
			
		end);
		
add_event_hook("stream-features", 
					function (session, features)												
						if not session.username then
							t_insert(features, "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>");
								t_insert(features, "<mechanism>PLAIN</mechanism>");
							t_insert(features, "</mechanisms>");
						else
							t_insert(features, "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><required/></bind>");
							t_insert(features, "<session xmlns='urn:ietf:params:xml:ns:xmpp-session'/>");
						end
						--send [[<register xmlns="http://jabber.org/features/iq-register"/> ]]
					end);
					
add_iq_handler("c2s", "urn:ietf:params:xml:ns:xmpp-bind", 
		function (session, stanza)
			log("debug", "Client tried to bind to a resource");
			local resource;
			if stanza.attr.type == "set" then
				local bind = stanza.tags[1];
				
				if bind and bind.attr.xmlns == xmlns_bind then
					resource = bind:child_with_name("resource");
					if resource then
						resource = resource[1];
					end
				end
			end
			local success, err = sm_bind_resource(session, resource);
			if not success then
				local reply = st.reply(stanza);
				reply.attr.type = "error";
				if err == "conflict" then
					reply:tag("error", { type = "modify" })
						:tag("conflict", { xmlns = xmlns_stanzas });
				elseif err == "constraint" then
					reply:tag("error", { type = "cancel" })
						:tag("resource-constraint", { xmlns = xmlns_stanzas });
				elseif err == "auth" then
					reply:tag("error", { type = "cancel" })
						:tag("not-allowed", { xmlns = xmlns_stanzas });
				end
				send(session, reply);
			else
				local reply = st.reply(stanza);
				reply:tag("bind", { xmlns = xmlns_bind})
					:tag("jid"):text(session.full_jid);
				send(session, reply);
			end
		end);
		
add_iq_handler("c2s", "urn:ietf:params:xml:ns:xmpp-session", 
		function (session, stanza)
			log("debug", "Client tried to bind to a resource");
			send(session, st.reply(stanza));
		end);
