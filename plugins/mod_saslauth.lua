
local st = require "util.stanza";
local send = require "core.sessionmanager".send_to_session;

local usermanager_validate_credentials = require "core.usermanager".validate_credentials;
local t_concat = table.concat;
local tostring = tostring;

local log = require "util.logger".init("mod_saslauth");

local xmlns_sasl ='urn:ietf:params:xml:ns:xmpp-sasl';

local new_connhandler = require "net.connhandlers".new;
local new_sasl = require "util.sasl".new;

add_handler("c2s_unauthed", "auth",
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