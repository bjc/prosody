describe("util.roles", function ()
	randomize(false);
	local roles;
	it("can be loaded", function ()
		roles = require "util.roles";
	end);
	local test_role;
	it("can create a new role", function ()
		test_role = roles.new();
		assert.is_not_nil(test_role);
		assert.is_truthy(roles.is_role(test_role));
	end);
	describe("role object", function ()
		it("is restrictive by default", function ()
			assert.falsy(test_role:may("my-permission"));
		end);
		it("allows you to set permissions", function ()
			test_role:set_permission("my-permission", true);
			assert.truthy(test_role:may("my-permission"));
		end);
		it("allows you to set negative permissions", function ()
			test_role:set_permission("my-other-permission", false);
			assert.falsy(test_role:may("my-other-permission"));
		end);
		it("does not allows you to override previously set permissions by default", function ()
			local ok, err = test_role:set_permission("my-permission", false);
			assert.falsy(ok);
			assert.is_equal("policy-already-exists", err);
			-- Confirm old permission still in place
			assert.truthy(test_role:may("my-permission"));
		end);
		it("allows you to explicitly override previously set permissions", function ()
			assert.truthy(test_role:set_permission("my-permission", false, true));
			assert.falsy(test_role:may("my-permission"));
		end);
		describe("inheritance", function ()
			local child_role;
			it("works", function ()
				test_role:set_permission("inherited-permission", true);
				child_role = roles.new({
					inherits = { test_role };
				});
				assert.truthy(child_role:may("inherited-permission"));
				assert.falsy(child_role:may("my-permission"));
			end);
			it("allows listing policies", function ()
				local expected = {
					["my-permission"] = false;
					["my-other-permission"] = false;
					["inherited-permission"] = true;
				};
				local received = {};
				for permission_name, permission_policy in child_role:policies() do
					received[permission_name] = permission_policy;
				end
				assert.same(expected, received);
			end);
			it("supports multiple depths of inheritance", function ()
				local grandchild_role = roles.new({
					inherits = { child_role };
				});
				assert.truthy(grandchild_role:may("inherited-permission"));
			end);
			describe("supports ordered inheritance from multiple roles", function ()
				local parent_role = roles.new();
				local final_role = roles.new({
					-- Yes, the names are getting confusing.
					-- btw, test_role is inherited through child_role.
					inherits = { parent_role, child_role };
				});

				local test_cases = {
					-- { <final_role policy>, <parent_role policy>, <test_role policy> }
					{ true,   nil, false, result = true };
					{  nil, false,  true, result = false };
					{  nil,  true, false, result = true };
					{  nil,  nil,  false, result = false };
					{  nil,  nil,   true, result = true };
				};

				for n, test_case in ipairs(test_cases) do
					it("(case "..n..")", function ()
						local perm_name = ("multi-inheritance-perm-%d"):format(n);
						assert.truthy(final_role:set_permission(perm_name, test_case[1]));
						assert.truthy(parent_role:set_permission(perm_name, test_case[2]));
						assert.truthy(test_role:set_permission(perm_name, test_case[3]));
						assert.equal(test_case.result, final_role:may(perm_name));
					end);
				end
			end);
			it("updates child roles when parent roles change", function ()
				assert.truthy(child_role:may("inherited-permission"));
				assert.truthy(test_role:set_permission("inherited-permission", false, true));
				assert.falsy(child_role:may("inherited-permission"));
			end);
		end);
		describe("cloning", function ()
			local cloned_role;
			it("works", function ()
				assert.truthy(test_role:set_permission("perm-1", true));
				cloned_role = test_role:clone();
				assert.truthy(cloned_role:may("perm-1"));
			end);
			it("isolates changes", function ()
				-- After cloning, changes in either the original or the clone
				-- should not appear in the other.
				assert.truthy(test_role:set_permission("perm-1", false, true));
				assert.truthy(test_role:set_permission("perm-2", true));
				assert.truthy(cloned_role:set_permission("perm-3", true));
				assert.truthy(cloned_role:may("perm-1"));
				assert.falsy(cloned_role:may("perm-2"));
				assert.falsy(test_role:may("perm-3"));
			end);
		end);
	end);
end);
