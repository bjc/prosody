
local st = require "util.stanza";
local send = require "core.sessionmanager".send_to_session;
local sm_bind_resource = require "core.sessionmanager".bind_resource;
local jid

local usermanager_validate_credentials = require "core.usermanager".validate_credentials;
local t_concat, t_insert = table.concat, table.insert;
local tostring = tostring;
local jid_split = require "util.jid".split

local log = require "util.logger".init("mod_saslauth");

local xmlns_sasl ='urn:ietf:params:xml:ns:xmpp-sasl';
local xmlns_bind ='urn:ietf:params:xml:ns:xmpp-bind';
local xmlns_stanzas ='urn:ietf:params:xml:ns:xmpp-stanzas';

local new_sasl = require "util.sasl".new;

local function build_reply(status, ret, err_msg)
	local reply = st.stanza(status, {xmlns = xmlns_sasl});
	if status == "challenge" then
		reply:text(ret or "");
	elseif status == "failure" then
		reply:tag(ret):up();
		if err_msg then reply:tag("text"); end
	elseif status == "success" then
		reply:text(ret or "");
	else
		error("Unknown sasl status: "..status);
	end
	return reply;
end

local function handle_status(session, status)
	if status == "failure" then
		session.sasl_handler = nil;
	elseif status == "success" then
		if not session.sasl_handler.username then error("SASL succeeded but we didn't get a username!"); end -- TODO move this to sessionmanager
		sessionmanager.make_authenticated(session, session.sasl_handler.username);
		session.sasl_handler = nil;
		session:reset_stream();
	end
end

local function password_callback(node, host, mechanism)
	local password = (datamanager.load(node, host, "accounts") or {}).password; -- FIXME handle hashed passwords
	local func = function(x) return x; end;
	if password then
		if mechanism == "PLAIN" then
			return func, password;
		elseif mechanism == "DIGEST-MD5" then
			return func, require "hashes".md5(node..":"..host..":"..password);
		end
	end
	return func, nil;
end

function do_sasl(session, stanza)
	local text = stanza[1];
	if text then
		text = base64.decode(text);
		if not text then
			session.sasl_handler = nil;
			session.send(build_reply("failure", "incorrect-encoding"));
			return;
		end
	end
	local status, ret, err_msg = session.sasl_handler:feed(text);
	handle_status(session, status);
	local s = build_reply(status, ret, err_msg); 
	log("debug", "sasl reply: "..tostring(s));
	session.send(s);
end

add_handler("c2s_unauthed", "auth", xmlns_sasl,
		function (session, stanza)
			if not session.sasl_handler then
				session.sasl_handler = new_sasl(stanza.attr.mechanism, session.host, password_callback);
				do_sasl(session, stanza);
			else
				error("Client tried to negotiate SASL again", 0);
			end
		end);

add_handler("c2s_unauthed", "abort", xmlns_sasl,
	function(session, stanza)
		if not session.sasl_handler then error("Attempt to abort when sasl has not started"); end
		do_sasl(session, stanza);
	end);

add_handler("c2s_unauthed", "response", xmlns_sasl,
	function(session, stanza)
		if not session.sasl_handler then error("Attempt to respond when sasl has not started"); end
		do_sasl(session, stanza);
	end);

add_event_hook("stream-features", 
					function (session, features)												
						if not session.username then
							t_insert(features, "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>");
							-- TODO: Provide PLAIN only if TLS is active, this is a SHOULD from the introduction of RFC 4616. This behavior could be overridden via configuration but will issuing a warning or so.
								t_insert(features, "<mechanism>PLAIN</mechanism>");
								-- t_insert(features, "<mechanism>DIGEST-MD5</mechanism>");
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
