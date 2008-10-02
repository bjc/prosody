
local lxp = require "lxp"
local init_xmlhandlers = require "core.xmlhandlers"

module "connhandlers"


function new(name, session)
	if name == "xmpp-client" then
		local parser = lxp.new(init_xmlhandlers(session), ":");
		local parse = parser.parse;
		return { data = function (self, data) return parse(parser, data); end, parser = parser }
	end
end

return _M;