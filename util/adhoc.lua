local function new_simple_form(form, result_handler)
	return function(self, data, state)
		if state then
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
		if state then
			if data.action == "cancel" then
				return { status = "canceled" };
			end
			local fields, err = form:data(data.form);
			return result_handler(fields, err, data);
		else
			return { status = "executing", actions = {"next", "complete", default = "complete"},
				 form = { layout = form, values = initial_data() } }, "executing";
		end
	end
end

return { new_simple_form = new_simple_form,
	 new_initial_data_form = new_initial_data_form };
