local id = require "util.id";
local jid = require "util.jid";
local base64 = require "util.encodings".base64;

local token_store = module:open_store("auth_tokens", "map");

function create_jid_token(actor_jid, token_jid, token_scope, token_ttl)
	token_jid = jid.prep(token_jid);
	if not actor_jid or token_jid ~= actor_jid and not jid.compare(token_jid, actor_jid) then
		return nil, "not-authorized";
	end

	local token_username, token_host, token_resource = jid.split(token_jid);

	if token_host ~= module.host then
		return nil, "invalid-host";
	end

	local token_info = {
		owner = actor_jid;
		expires = token_ttl and (os.time() + token_ttl) or nil;
		jid = token_jid;
		session = {
			username = token_username;
			host = token_host;
			resource = token_resource;

			auth_scope = token_scope;
		};
	};

	local token_id = id.long();
	local token = base64.encode("1;"..jid.join(token_username, token_host)..";"..token_id);
	token_store:set(token_username, token_id, token_info);

	return token, token_info;
end

local function parse_token(encoded_token)
	local token = base64.decode(encoded_token);
	if not token then return nil; end
	local token_jid, token_id = token:match("^1;([^;]+);(.+)$");
	if not token_jid then return nil; end
	local token_user, token_host = jid.split(token_jid);
	return token_id, token_user, token_host;
end

function get_token_info(token)
	local token_id, token_user, token_host = parse_token(token);
	if not token_id then
		return nil, "invalid-token-format";
	end
	if token_host ~= module.host then
		return nil, "invalid-host";
	end

	local token_info, err = token_store:get(token_user, token_id);
	if not token_info then
		if err then
			return nil, "internal-error";
		end
		return nil, "not-authorized";
	end

	if token_info.expires and token_info.expires < os.time() then
		return nil, "not-authorized";
	end

	return token_info
end

function revoke_token(token)
	local token_id, token_user, token_host = parse_token(token);
	if not token_id then
		return nil, "invalid-token-format";
	end
	if token_host ~= module.host then
		return nil, "invalid-host";
	end
	return token_store:set(token_user, token_id, nil);
end
