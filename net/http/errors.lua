-- This module returns a table that is suitable for use as a util.error registry,
-- and a function to return a util.error object given callback 'code' and 'body'
-- parameters.

local codes = require "net.http.codes";
local util_error = require "util.error";

local error_templates = {
	-- This code is used by us to report a client-side or connection error.
	-- Instead of using the code, use the supplied body text to get one of
	-- the more detailed errors below.
	[0] = {
		code = 0, type = "cancel", condition = "internal-server-error";
		text = "Connection or internal error";
	};

	-- These are net.http built-in errors, they are returned in
	-- the body parameter when code == 0
	["cancelled"] = {
		code = 0, type = "cancel", condition = "remote-server-timeout";
		text = "Request cancelled";
	};
	["connection-closed"] = {
		code = 0, type = "wait", condition = "remote-server-timeout";
		text = "Connection closed";
	};
	["certificate-chain-invalid"] = {
		code = 0, type = "cancel", condition = "remote-server-timeout";
		text = "Server certificate not trusted";
	};
	["certificate-verify-failed"] = {
		code = 0, type = "cancel", condition = "remote-server-timeout";
		text = "Server certificate invalid";
	};
	["connection failed"] = {
		code = 0, type = "cancel", condition = "remote-server-not-found";
		text = "Connection failed";
	};
	["invalid-url"] = {
		code = 0, type = "modify", condition = "bad-request";
		text = "Invalid URL";
	};

	-- This doesn't attempt to map every single HTTP code (not all have sane mappings),
	-- but all the common ones should be covered. XEP-0086 was used as reference for
	-- most of these.
	[400] = { type = "modify", condition = "bad-request" };
	[401] = { type = "auth", condition = "not-authorized" };
	[402] = { type = "auth", condition = "payment-required" };
	[403] = { type = "auth", condition = "forbidden" };
	[404] = { type = "cancel", condition = "item-not-found" };
	[405] = { type = "cancel", condition = "not-allowed" };
	[406] = { type = "modify", condition = "not-acceptable" };
	[407] = { type = "auth", condition = "registration-required" };
	[408] = { type = "wait", condition = "remote-server-timeout" };
	[409] = { type = "cancel", condition = "conflict" };
	[410] = { type = "cancel", condition = "gone" };
	[411] = { type = "modify", condition = "bad-request" };
	[412] = { type = "cancel", condition = "conflict" };
	[413] = { type = "modify", condition = "resource-constraint" };
	[414] = { type = "modify", condition = "resource-constraint" };
	[415] = { type = "cancel", condition = "feature-not-implemented" };
	[416] = { type = "modify", condition = "bad-request" };

	[422] = { type = "modify", condition = "bad-request" };
	[423] = { type = "wait", condition = "resource-constraint" };

	[429] = { type = "wait", condition = "resource-constraint" };
	[431] = { type = "modify", condition = "resource-constraint" };
	[451] = { type = "auth", condition = "forbidden" };

	[500] = { type = "wait", condition = "internal-server-error" };
	[501] = { type = "cancel", condition = "feature-not-implemented" };
	[502] = { type = "wait", condition = "remote-server-timeout" };
	[503] = { type = "cancel", condition = "service-unavailable" };
	[504] = { type = "wait", condition = "remote-server-timeout" };
	[507] = { type = "wait", condition = "resource-constraint" };
	[511] = { type = "auth", condition = "not-authorized" };
};

for k, v in pairs(codes) do
	if error_templates[k] then
		error_templates[k].code = k;
		error_templates[k].text = v;
	else
		error_templates[k] = { type = "cancel", condition = "undefined-condition", text = v, code = k };
	end
end

setmetatable(error_templates, {
	__index = function(_, k)
		if type(k) ~= "number" then
			return nil;
		end
		return {
			type = "cancel";
			condition = "undefined-condition";
			text = codes[k] or (k.." Unassigned");
			code = k;
		};
	end
});

local function new(code, body, context)
	if code == 0 then
		return util_error.new(body, context, error_templates);
	else
		return util_error.new(code, context, error_templates);
	end
end

return {
	registry = error_templates;
	new = new;
};
