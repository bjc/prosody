
local helper = require "util.discohelper".new();
local hosts = hosts;
local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local usermanager_user_exists = require "core.usermanager".user_exists;
local rostermanager_is_contact_subscribed = require "core.rostermanager".is_contact_subscribed;

do
	helper:addDiscoInfoHandler("*host", function(reply, to, from, node)
		if hosts[to] then
			reply:tag("identity", {category="server", type="im", name="ejabberd"}):up();
			return true;
		end
	end);
	helper:addDiscoInfoHandler("*node", function(reply, to, from, node)
		local node, host = jid_split(to);
		if hosts[host] and rostermanager_is_contact_subscribed(node, host, jid_bare(from)) then
			reply:tag("identity", {category="account", type="registered"}):up();
			return true;
		end
	end);
end

module "discomanager"

function handle(stanza)
	return helper:handle(stanza);
end

function addDiscoItemsHandler(jid, func)
	return helper:addDiscoItemsHandler(jid, func);
end

function addDiscoInfoHandler(jid, func)
	return helper:addDiscoInfoHandler(jid, func);
end

return _M;
