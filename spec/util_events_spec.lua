local events = require "util.events";

describe("util.events", function ()
	it("should export a new() function", function ()
		assert.is_function(events.new);
	end);
	describe("new()", function ()
		it("should return return a new events object", function ()
			local e = events.new();
			assert.is_function(e.add_handler);
			assert.is_function(e.remove_handler);
		end);
	end);

	local e, h;


	describe("API", function ()
		before_each(function ()
			e = events.new();
			h = spy.new(function () end);
		end);

		it("should call handlers when an event is fired", function ()
			e.add_handler("myevent", h);
			e.fire_event("myevent");
			assert.spy(h).was_called();
		end);

		it("should not call handlers when a different event is fired", function ()
			e.add_handler("myevent", h);
			e.fire_event("notmyevent");
			assert.spy(h).was_not_called();
		end);

		it("should pass the data argument to handlers", function ()
			e.add_handler("myevent", h);
			e.fire_event("myevent", "mydata");
			assert.spy(h).was_called_with("mydata");
		end);

		it("should support non-string events", function ()
			local myevent = {};
			e.add_handler(myevent, h);
			e.fire_event(myevent, "mydata");
			assert.spy(h).was_called_with("mydata");
		end);

		it("should call handlers in priority order", function ()
			local data = {};
			e.add_handler("myevent", function () table.insert(data, "h1"); end, 5);
			e.add_handler("myevent", function () table.insert(data, "h2"); end, 3);
			e.add_handler("myevent", function () table.insert(data, "h3"); end);
			e.fire_event("myevent", "mydata");
			assert.same(data, { "h1", "h2", "h3" });
		end);

		it("should support non-integer priority values", function ()
			local data = {};
			e.add_handler("myevent", function () table.insert(data, "h1"); end, 1);
			e.add_handler("myevent", function () table.insert(data, "h2"); end, 0.5);
			e.add_handler("myevent", function () table.insert(data, "h3"); end, 0.25);
			e.fire_event("myevent", "mydata");
			assert.same(data, { "h1", "h2", "h3" });
		end);

		it("should support negative priority values", function ()
			local data = {};
			e.add_handler("myevent", function () table.insert(data, "h1"); end, 1);
			e.add_handler("myevent", function () table.insert(data, "h2"); end, 0);
			e.add_handler("myevent", function () table.insert(data, "h3"); end, -1);
			e.fire_event("myevent", "mydata");
			assert.same(data, { "h1", "h2", "h3" });
		end);

		it("should support removing handlers", function ()
			e.add_handler("myevent", h);
			e.fire_event("myevent");
			e.remove_handler("myevent", h);
			e.fire_event("myevent");
			assert.spy(h).was_called(1);
		end);

		it("should support adding multiple handlers at the same time", function ()
			local ht = {
				myevent1 = spy.new(function () end);
				myevent2 = spy.new(function () end);
				myevent3 = spy.new(function () end);
			};
			e.add_handlers(ht);
			e.fire_event("myevent1");
			e.fire_event("myevent2");
			assert.spy(ht.myevent1).was_called();
			assert.spy(ht.myevent2).was_called();
			assert.spy(ht.myevent3).was_not_called();
		end);

		it("should support removing multiple handlers at the same time", function ()
			local ht = {
				myevent1 = spy.new(function () end);
				myevent2 = spy.new(function () end);
				myevent3 = spy.new(function () end);
			};
			e.add_handlers(ht);
			e.remove_handlers(ht);
			e.fire_event("myevent1");
			e.fire_event("myevent2");
			assert.spy(ht.myevent1).was_not_called();
			assert.spy(ht.myevent2).was_not_called();
			assert.spy(ht.myevent3).was_not_called();
		end);

		pending("should support adding handlers within an event handler")
		pending("should support removing handlers within an event handler")

		it("should support getting the current handlers for an event", function ()
			e.add_handler("myevent", h);
			local handlers = e.get_handlers("myevent");
			assert.equal(h, handlers[1]);
		end);

		describe("wrappers", function ()
			local w
			before_each(function ()
				w = spy.new(function (handlers, event_name, event_data)
					assert.is_function(handlers);
					assert.equal("myevent", event_name)
					assert.equal("abc", event_data);
					return handlers(event_name, event_data);
				end);
			end);

			it("should get called", function ()
				e.add_wrapper("myevent", w);
				e.add_handler("myevent", h);
				e.fire_event("myevent", "abc");
				assert.spy(w).was_called(1);
				assert.spy(h).was_called(1);
			end);

			it("should be removable", function ()
				e.add_wrapper("myevent", w);
				e.add_handler("myevent", h);
				e.fire_event("myevent", "abc");
				e.remove_wrapper("myevent", w);
				e.fire_event("myevent", "abc");
				assert.spy(w).was_called(1);
				assert.spy(h).was_called(2);
			end);

			it("should allow multiple wrappers", function ()
				local w2 = spy.new(function (handlers, event_name, event_data)
					return handlers(event_name, event_data);
				end);
				e.add_wrapper("myevent", w);
				e.add_handler("myevent", h);
				e.add_wrapper("myevent", w2);
				e.fire_event("myevent", "abc");
				e.remove_wrapper("myevent", w);
				e.fire_event("myevent", "abc");
				assert.spy(w).was_called(1);
				assert.spy(w2).was_called(2);
				assert.spy(h).was_called(2);
			end);

			it("should support a mix of global and event wrappers", function ()
				local w2 = spy.new(function (handlers, event_name, event_data)
					return handlers(event_name, event_data);
				end);
				e.add_wrapper(false, w);
				e.add_handler("myevent", h);
				e.add_wrapper("myevent", w2);
				e.fire_event("myevent", "abc");
				e.remove_wrapper(false, w);
				e.fire_event("myevent", "abc");
				assert.spy(w).was_called(1);
				assert.spy(w2).was_called(2);
				assert.spy(h).was_called(2);
			end);
		end);

		describe("global wrappers", function ()
			local w
			before_each(function ()
				w = spy.new(function (handlers, event_name, event_data)
					assert.is_function(handlers);
					assert.equal("myevent", event_name)
					assert.equal("abc", event_data);
					return handlers(event_name, event_data);
				end);
			end);

			it("should get called", function ()
				e.add_wrapper(false, w);
				e.add_handler("myevent", h);
				e.fire_event("myevent", "abc");
				assert.spy(w).was_called(1);
				assert.spy(h).was_called(1);
			end);

			it("should be removable", function ()
				e.add_wrapper(false, w);
				e.add_handler("myevent", h);
				e.fire_event("myevent", "abc");
				e.remove_wrapper(false, w);
				e.fire_event("myevent", "abc");
				assert.spy(w).was_called(1);
				assert.spy(h).was_called(2);
			end);
		end);

		describe("debug hooks", function ()
			it("should get called", function ()
				local d = spy.new(function (handler, event_name, event_data)
					return handler(event_data);
				end);

				e.add_handler("myevent", h);
				e.fire_event("myevent");

				assert.spy(h).was_called(1);
				assert.spy(d).was_called(0);

				assert.is_nil(e.set_debug_hook(d));

				e.fire_event("myevent", { mydata = true });

				assert.spy(h).was_called(2);
				assert.spy(d).was_called(1);
				assert.spy(d).was_called_with(h, "myevent", { mydata = true });

				assert.equal(d, e.set_debug_hook(nil));

				e.fire_event("myevent", { mydata = false });

				assert.spy(h).was_called(3);
				assert.spy(d).was_called(1);
			end);
			it("setting should return any existing debug hook", function ()
				local function f() end
				local function g() end
				assert.is_nil(e.set_debug_hook(f));
				assert.is_equal(f, e.set_debug_hook(g));
				assert.is_equal(g, e.set_debug_hook(f));
				assert.is_equal(f, e.set_debug_hook(nil));
				assert.is_nil(e.set_debug_hook(f));
			end);
		end);
	end);
end);
