local it = require "prosody.util.iterators";
local st = require "prosody.util.stanza";

local pubsub_lib = module:require("mod_pubsub/pubsub");

local function add_commands(get_service)
	module:add_item("shell-command", {
		section = "pubsub";
		section_desc = "Manage publish/subscribe nodes";
		name = "list_nodes";
		desc = "List nodes on a pubsub service";
		args = {
			{ name = "service_jid", type = "string" };
		};
		host_selector = "service_jid";

		handler = function (self, service_jid) --luacheck: ignore 212/self
			-- luacheck: ignore 431/service
			local service = get_service(service_jid);
			local nodes = select(2, assert(service:get_nodes(true)));
			local count = 0;
			for node_name in pairs(nodes) do
				count = count + 1;
				self.session.print(node_name);
			end
			return true, ("%d nodes"):format(count);
		end;
	});

	module:add_item("shell-command", {
		section = "pubsub";
		section_desc = "Manage publish/subscribe nodes";
		name = "list_items";
		desc = "List items on a pubsub node";
		args = {
			{ name = "service_jid", type = "string" };
			{ name = "node_name", type = "string" };
		};
		host_selector = "service_jid";

		handler = function (self, service_jid, node_name) --luacheck: ignore 212/self
			-- luacheck: ignore 431/service
			local service = get_service(service_jid);
			local items = select(2, assert(service:get_items(node_name, true)));

			local count = 0;
			for item_name in pairs(items) do
				count = count + 1;
				self.session.print(item_name);
			end
			return true, ("%d items"):format(count);
		end;
	});

	module:add_item("shell-command", {
		section = "pubsub";
		section_desc = "Manage publish/subscribe nodes";
		name = "get_item";
		desc = "Show item content on a pubsub node";
		args = {
			{ name = "service_jid", type = "string" };
			{ name = "node_name", type = "string" };
			{ name = "item_name", type = "string" };
		};
		host_selector = "service_jid";

		handler = function (self, service_jid, node_name, item_name) --luacheck: ignore 212/self
			-- luacheck: ignore 431/service
			local service = get_service(service_jid);
			local items = select(2, assert(service:get_items(node_name, true)));

			if not items[item_name] then
				return false, "Item not found";
			end

			self.session.print(items[item_name]);

			return true;
		end;
	});

	module:add_item("shell-command", {
		section = "pubsub";
		section_desc = "Manage publish/subscribe nodes";
		name = "get_node_config";
		desc = "Get the current configuration for a node";
		args = {
			{ name = "service_jid", type = "string" };
			{ name = "node_name", type = "string" };
			{ name = "option_name", type = "string" };
		};
		host_selector = "service_jid";

		handler = function (self, service_jid, node_name, option_name) --luacheck: ignore 212/self
			-- luacheck: ignore 431/service
			local service = get_service(service_jid);
			local config = select(2, assert(service:get_node_config(node_name, true)));

			local config_form = pubsub_lib.node_config_form:form(config, "submit");

			local count = 0;
			if option_name then
				count = 1;
				local field = config_form:get_child_with_attr("field", nil, "var", option_name);
				if not field then
					return false, "option not found";
				end
				self.session.print(field:get_child_text("value"));
			else
				local opts = {};
				for field in config_form:childtags("field") do
					opts[field.attr.var] = field:get_child_text("value");
				end
				for k, v in it.sorted_pairs(opts) do
					count = count + 1;
					self.session.print(k, v);
				end
			end

			return true, ("Showing %d config options"):format(count);
		end;
	});

	module:add_item("shell-command", {
		section = "pubsub";
		section_desc = "Manage publish/subscribe nodes";
		name = "set_node_config_option";
		desc = "Set a config option on a pubsub node";
		args = {
			{ name = "service_jid", type = "string" };
			{ name = "node_name", type = "string" };
			{ name = "option_name", type = "string" };
			{ name = "option_value", type = "string" };
		};
		host_selector = "service_jid";

		handler = function (self, service_jid, node_name, option_name, option_value) --luacheck: ignore 212/self
			-- luacheck: ignore 431/service
			local service = get_service(service_jid);
			local config = select(2, assert(service:get_node_config(node_name, true)));

			local new_config_form = st.stanza("x", { xmlns = "jabber:x:data" })
				:tag("field", { var = option_name })
					:text_tag("value", option_value)
				:up();

			local new_config = pubsub_lib.node_config_form:data(new_config_form, config);

			assert(service:set_node_config(node_name, true, new_config));

			local applied_config = select(2, assert(service:get_node_config(node_name, true)));

			local applied_config_form = pubsub_lib.node_config_form:form(applied_config, "submit");
			local applied_field = applied_config_form:get_child_with_attr("field", nil, "var", option_name);
			if not applied_field then
				return false, "Unknown config field: "..option_name;
			end
			return true, "Applied config: "..applied_field:get_child_text("value");
		end;
	});

	module:add_item("shell-command", {
		section = "pubsub";
		section_desc = "Manage publish/subscribe nodes";
		name = "delete_item";
		desc = "Delete a single item from a node";
		args = {
			{ name = "service_jid", type = "string" };
			{ name = "node_name", type = "string" };
			{ name = "item_name", type = "string" };
		};
		host_selector = "service_jid";

		handler = function (self, service_jid, node_name, item_name) --luacheck: ignore 212/self
			-- luacheck: ignore 431/service
			local service = get_service(service_jid);
			return assert(service:retract(node_name, true, item_name));
		end;
	});

	module:add_item("shell-command", {
		section = "pubsub";
		section_desc = "Manage publish/subscribe nodes";
		name = "delete_all_items";
		desc = "Delete all items from a node";
		args = {
			{ name = "service_jid", type = "string" };
			{ name = "node_name", type = "string" };
			{ name = "notify_subscribers", type = "string" };
		};
		host_selector = "service_jid";

		handler = function (self, service_jid, node_name, notify_subscribers) --luacheck: ignore 212/self
			-- luacheck: ignore 431/service
			local service = get_service(service_jid);
			return assert(service:purge(node_name, true, notify_subscribers == "true"));
		end;
	});

	module:add_item("shell-command", {
		section = "pubsub";
		section_desc = "Manage publish/subscribe nodes";
		name = "create_node";
		desc = "Create a new node";
		args = {
			{ name = "service_jid", type = "string" };
			{ name = "node_name", type = "string" };
		};
		host_selector = "service_jid";

		handler = function (self, service_jid, node_name) --luacheck: ignore 212/self
			-- luacheck: ignore 431/service
			local service = get_service(service_jid);
			return assert(service:create(node_name, true));
		end;
	});

	module:add_item("shell-command", {
		section = "pubsub";
		section_desc = "Manage publish/subscribe nodes";
		name = "delete_node";
		desc = "Delete a node entirely";
		args = {
			{ name = "service_jid", type = "string" };
			{ name = "node_name", type = "string" };
		};
		host_selector = "service_jid";

		handler = function (self, service_jid, node_name) --luacheck: ignore 212/self
			-- luacheck: ignore 431/service
			local service = get_service(service_jid);
			return assert(service:delete(node_name, true));
		end;
	});
end

return {
	add_commands = add_commands;
}
