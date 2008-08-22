
require "util.stanza"

local st = stanza;

local t_concat = table.concat;
local format = string.format;

function init_stanza_dispatcher(session)
	local iq_handlers = {};

	local session_log = session.log;
	local log = function (type, msg) session_log(type, "stanza_dispatcher", msg); end
	local send = session.send;



	iq_handlers["jabber:iq:auth"] = 
		function (stanza)
			local username = stanza[1]:child_with_name("username");
			local password = stanza[1]:child_with_name("password");
			local resource = stanza[1]:child_with_name("resource");
			if not (username and password and resource) then
				local reply = st.reply(stanza);
				send(reply:query("jabber:iq:auth")
					:tag("username"):up()
					:tag("password"):up()
					:tag("resource"):up());
				return true;			
			else
				username, password, resource = t_concat(username), t_concat(password), t_concat(resource);
				print(username, password, resource)
				local reply = st.reply(stanza);
				require "core.usermanager"
				if usermanager.validate_credentials(session.host, username, password) then
					-- Authentication successful!
					session.username = username;
					session.resource = resource;
					if not hosts[session.host].sessions[username] then
						hosts[session.host].sessions[username] = { sessions = {} };
					end
					hosts[session.host].sessions[username].sessions[resource] = session;
					send(st.reply(stanza));
					return true;
				else
					local reply = st.reply(stanza);
					reply.attr.type = "error";
					reply:tag("error", { code = "401", type = "auth" })
						:tag("not-authorized", { xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas" });
					send(reply);
					return true;
				end
			end
			
		end
		
	iq_handlers["jabber:iq:roster"] =
		function (stanza)
			if stanza.attr.type == "get" then
				session.roster = session.roster or rostermanager.getroster(session.username, session.host);
				if session.roster == false then
					send(st.reply(stanza)
						:tag("error", { type = "wait" })
						:tag("internal-server-error", { xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas"}));
					return true;
				else session.roster = session.roster or {};
				end
				local roster = st.reply(stanza)
							:query("jabber:iq:roster");
				for jid in pairs(session.roster) do
					roster:tag("item", { jid = jid, subscription = "none" }):up();
				end
				send(roster);
				return true;
			end
		end


	return	function (stanza)
			log("info", "--> "..tostring(stanza));
			if stanza.name == "iq" then
				if not stanza[1] then log("warn", "<iq> without child is invalid"); return; end
				if not stanza.attr.id then log("warn", "<iq> without id attribute is invalid"); end
				local xmlns = stanza[1].attr.xmlns;
				if not xmlns then log("warn", "Child of <iq> has no xmlns - invalid"); return; end
				if (((not stanza.attr.to) or stanza.attr.to == session.host or stanza.attr.to:match("@[^/]+$")) and (stanza.attr.type == "get" or stanza.attr.type == "set")) then -- Stanza sent to us
					if iq_handlers[xmlns] then
						if iq_handlers[xmlns](stanza) then return; end;
					end
					log("warn", "Unhandled namespace: "..xmlns);
					send(format("<iq type='error' id='%s'><error type='cancel'><service-unavailable/></error></iq>", stanza.attr.id));
				end
			
			end
							-- Need to route stanza
			if stanza.attr.to and ((not hosts[stanza.attr.to]) or hosts[stanza.attr.to].type ~= "local") then
				stanza.attr.from = session.username.."@"..session.host;
				session.send_to(stanza.attr.to, stanza);
			end
		end

end

