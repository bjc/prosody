

local log = require "util.logger".init("componentmanager")
local jid_split = require "util.jid".split;
local hosts = hosts;

local components = {};

module "componentmanager"

function handle_stanza(origin, stanza)
	local node, host = jid_split(stanza.attr.to);
	local component = components[host];
	if not component then component = components[node.."@"..host]; end -- hack to allow hooking node@server
	if not component then component = components[stanza.attr.to]; end -- hack to allow hooking node@server/resource and server/resource
	if component then
		log("debug", "stanza being handled by component: "..host);
		component(origin, stanza, hosts[host]);
	else
		log("error", "Component manager recieved a stanza for a non-existing component: " .. stanza.attr.to);
	end
end

function register_component(host, component)
	if not hosts[host] then
		-- TODO check for host well-formedness
		components[host] = component;
		hosts[host] = {type = "component", host = host, connected = true, s2sout = {} };
		log("debug", "component added: "..host);
		return hosts[host];
	else
		log("error", "Attempt to set component for existing host: "..host);
	end
end

return _M;
