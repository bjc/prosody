describe("util.fsm", function ()
	local new_fsm = require "util.fsm".new;

	do
		local fsm = new_fsm({
			transitions = {
				{ name = "melt", from = "solid", to = "liquid" };
				{ name = "freeze", from = "liquid", to = "solid" };
			};
		});

		it("works", function ()
			local water = fsm:init("liquid");
			water:freeze();
			assert.equal("solid", water.state);
			water:melt();
			assert.equal("liquid", water.state);
		end);

		it("does not allow invalid transitions", function ()
			local water = fsm:init("liquid");
			assert.has_errors(function ()
				water:melt();
			end, "Invalid state transition: liquid cannot melt");

			water:freeze();
			assert.equal("solid", water.state);

			water:melt();
			assert.equal("liquid", water.state);

			assert.has_errors(function ()
				water:melt();
			end, "Invalid state transition: liquid cannot melt");
		end);
	end

	it("notifies observers", function ()
		local n = 0;
		local has_become_solid = spy.new(function (transition)
			assert.is_table(transition);
			assert.equal("solid", transition.to);
			assert.is_not_nil(transition.instance);
			n = n + 1;
			if n == 1 then
				assert.is_nil(transition.from);
				assert.is_nil(transition.from_attr);
			elseif n == 2 then
				assert.equal("liquid", transition.from);
				assert.is_nil(transition.from_attr);
				assert.equal("freeze", transition.name);
			end
		end);
		local is_melting = spy.new(function (transition)
			assert.is_table(transition);
			assert.equal("melt", transition.name);
			assert.is_not_nil(transition.instance);
		end);
		local fsm = new_fsm({
			transitions = {
				{ name = "melt", from = "solid", to = "liquid" };
				{ name = "freeze", from = "liquid", to = "solid" };
			};
			state_handlers = {
				solid = has_become_solid;
			};

			transition_handlers = {
				melt = is_melting;
			};
		});

		local water = fsm:init("liquid");
		assert.spy(has_become_solid).was_not_called();

		local ice = fsm:init("solid"); --luacheck: ignore 211/ice
		assert.spy(has_become_solid).was_called(1);

		water:freeze();

		assert.spy(is_melting).was_not_called();
		water:melt();
		assert.spy(is_melting).was_called(1);
	end);

	local function test_machine(fsm_spec, expected_transitions, test_func)
		fsm_spec.handlers = fsm_spec.handlers or {};
		fsm_spec.handlers.transitioned = function (transition)
			local expected_transition = table.remove(expected_transitions, 1);
			assert.same(expected_transition, {
				name = transition.name;
				to = transition.to;
				to_attr = transition.to_attr;
				from = transition.from;
				from_attr = transition.from_attr;
			});
		end;
		local fsm = new_fsm(fsm_spec);
		test_func(fsm);
		assert.equal(0, #expected_transitions);
	end


	it("handles transitions with the same name", function ()
		local expected_transitions = {
			{ name = nil   , from = "none", to = "A" };
			{ name = "step", from = "A", to = "B" };
			{ name = "step", from = "B", to = "C" };
			{ name = "step", from = "C", to = "D" };
		};

		test_machine({
			default_state = "none";
			transitions = {
				{ name = "step", from = "A", to = "B" };
				{ name = "step", from = "B", to = "C" };
				{ name = "step", from = "C", to = "D" };
			};
		}, expected_transitions, function (fsm)
			local i = fsm:init("A");
			i:step(); -- B
			i:step(); -- C
			i:step(); -- D
			assert.has_errors(function ()
				i:step();
			end, "Invalid state transition: D cannot step");
		end);
	end);

	it("handles supports wildcard transitions", function ()
		local expected_transitions = {
			{ name = nil   , from = "none", to = "A" };
			{ name = "step", from = "A", to = "B" };
			{ name = "step", from = "B", to = "C" };
			{ name = "reset", from = "C", to = "A" };
			{ name = "step", from = "A", to = "B" };
			{ name = "step", from = "B", to = "C" };
			{ name = "step", from = "C", to = "D" };
		};

		test_machine({
			default_state = "none";
			transitions = {
				{ name = "step", from = "A", to = "B" };
				{ name = "step", from = "B", to = "C" };
				{ name = "step", from = "C", to = "D" };
				{ name = "reset", from = "*", to = "A" };
			};
		}, expected_transitions, function (fsm)
			local i = fsm:init("A");
			i:step(); -- B
			i:step(); -- C
			i:reset(); -- A
			i:step(); -- B
			i:step(); -- C
			i:step(); -- D
			assert.has_errors(function ()
				i:step();
			end, "Invalid state transition: D cannot step");
		end);
	end);

	it("supports specifying multiple from states", function ()
		local expected_transitions = {
			{ name = nil   , from = "none", to = "A" };
			{ name = "step", from = "A", to = "B" };
			{ name = "step", from = "B", to = "C" };
			{ name = "reset", from = "C", to = "A" };
			{ name = "step", from = "A", to = "B" };
			{ name = "step", from = "B", to = "C" };
			{ name = "step", from = "C", to = "D" };
		};

		test_machine({
			default_state = "none";
			transitions = {
				{ name = "step", from = "A", to = "B" };
				{ name = "step", from = "B", to = "C" };
				{ name = "step", from = "C", to = "D" };
				{ name = "reset", from = {"B", "C", "D"}, to = "A" };
			};
		}, expected_transitions, function (fsm)
			local i = fsm:init("A");
			i:step(); -- B
			i:step(); -- C
			i:reset(); -- A
			assert.has_errors(function ()
				i:reset();
			end, "Invalid state transition: A cannot reset");
			i:step(); -- B
			i:step(); -- C
			i:step(); -- D
			assert.has_errors(function ()
				i:step();
			end, "Invalid state transition: D cannot step");
		end);
	end);

	it("handles transitions with the same start/end state", function ()
		local expected_transitions = {
			{ name = nil   , from = "none", to = "A" };
			{ name = "step", from = "A", to = "B" };
			{ name = "step", from = "B", to = "B" };
			{ name = "step", from = "B", to = "B" };
		};

		test_machine({
			default_state = "none";
			transitions = {
				{ name = "step", from = "A", to = "B" };
				{ name = "step", from = "B", to = "B" };
			};
		}, expected_transitions, function (fsm)
			local i = fsm:init("A");
			i:step(); -- B
			i:step(); -- B
			i:step(); -- B
		end);
	end);

	it("can identify instances of a specific fsm", function ()
		local fsm1 = new_fsm({ default_state = "a" });
		local fsm2 = new_fsm({ default_state = "a" });

		local i1 = fsm1:init();
		local i2 = fsm2:init();

		assert.truthy(fsm1:is_instance(i1));
		assert.truthy(fsm2:is_instance(i2));

		assert.falsy(fsm1:is_instance(i2));
		assert.falsy(fsm2:is_instance(i1));
	end);

	it("errors when an invalid initial state is passed", function ()
		local fsm1 = new_fsm({
			transitions = {
				{ name = "", from = "A", to = "B" };
			};
		});

		assert.has_no_errors(function ()
			fsm1:init("A");
		end);

		assert.has_errors(function ()
			fsm1:init("C");
		end);
	end);
end);
