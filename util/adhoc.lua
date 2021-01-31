-- luacheck: ignore 212/self

local function new_simple_form(form, result_handler)
	return function(self, data, state)
		if state or data.form then
			if data.action == "cancel" then
				return { status = "canceled" };
			end
			local fields, err = form:data(data.form);
			return result_handler(fields, err, data);
		else
			return { status = "executing", actions = {"next", "complete", default = "complete"}, form = form }, "executing";
		end
	end
end

local function new_initial_data_form(form, initial_data, result_handler)
	return function(self, data, state)
		if state or data.form then
			if data.action == "cancel" then
				return { status = "canceled" };
			end
			local fields, err = form:data(data.form);
			return result_handler(fields, err, data);
		else
			local values, err = initial_data(data);
			if type(err) == "table" then
				return {status = "error"; error = err}
			elseif type(err) == "string" then
				return {status = "error"; error = {type = "cancel"; condition = "internal-server-error", err}}
			end
			return { status = "executing", actions = {"next", "complete", default = "complete"},
				 form = { layout = form, values = values } }, "executing";
		end
	end
end

return { new_simple_form = new_simple_form,
	 new_initial_data_form = new_initial_data_form };
