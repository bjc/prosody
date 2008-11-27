
local st = require "util.stanza";
local datetime = require "util.datetime".datetime;
local legacy = require "util.datetime".legacy;

-- XEP-0202: Entity Time

require "core.discomanager".set("time", "urn:xmpp:time");

module:add_iq_handler({"c2s", "s2sin"}, "urn:xmpp:time",
	function(session, stanza)
		if stanza.attr.type == "get" then
			session.send(st.reply(stanza):tag("time", {xmlns="urn:xmpp:time"})
				:tag("tzo"):text("+00:00"):up() -- FIXME get the timezone in a platform independent fashion
				:tag("utc"):text(datetime()));
		end
	end);

-- XEP-0090: Entity Time (deprecated)

require "core.discomanager".set("time", "jabber:iq:time");

module:add_iq_handler({"c2s", "s2sin"}, "jabber:iq:time",
	function(session, stanza)
		if stanza.attr.type == "get" then
			session.send(st.reply(stanza):tag("query", {xmlns="jabber:iq:time"})
				:tag("utc"):text(legacy()));
		end
	end);
