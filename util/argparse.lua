local function parse(arg, config)
	local short_params = config and config.short_params or {};
	local value_params = config and config.value_params or {};

	local parsed_opts = {};

	if #arg == 0 then
		return parsed_opts;
	end
	while true do
		local raw_param = arg[1];
		if not raw_param then
			break;
		end

		local prefix = raw_param:match("^%-%-?");
		if not prefix then
			break;
		elseif prefix == "--" and raw_param == "--" then
			table.remove(arg, 1);
			break;
		end
		local param = table.remove(arg, 1):sub(#prefix+1);
		if #param == 1 and short_params then
			param = short_params[param];
		end

		if not param then
			return nil, "param-not-found", raw_param;
		end

		local param_k, param_v;
		if value_params[param] then
			param_k, param_v = param, table.remove(arg, 1);
			if not param_v then
				return nil, "missing-value", raw_param;
			end
		else
			param_k, param_v = param:match("^([^=]+)=(.+)$");
			if not param_k then
				if param:match("^no%-") then
					param_k, param_v = param:sub(4), false;
				else
					param_k, param_v = param, true;
				end
			end
		end
		parsed_opts[param_k] = param_v;
	end
	return parsed_opts;
end

return {
	parse = parse;
}
