
local st = require "util.stanza";
local send = require "core.sessionmanager".send_to_session;

local log = require "util.logger".init("mod_version");

local xmlns_version = "jabber:iq:version"

local function handle_version_request(session, stanza)
			if stanza.attr.type == "get" then
				session.send(st.reply(stanza)
								:query(xmlns_version)
									:tag("name"):text("lxmppd"):up()
									:tag("version"):text("pre-alpha"):up()
									:tag("os"):text("The best one"));
			end
end

add_iq_handler("c2s", xmlns_version, handle_version_request);
add_iq_handler("s2sin", xmlns_version, handle_version_request);
