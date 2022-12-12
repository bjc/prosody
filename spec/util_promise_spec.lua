local promise = require "util.promise";

describe("util.promise", function ()
	--luacheck: ignore 212/resolve 212/reject
	describe("new()", function ()
		it("returns a promise object", function ()
			assert(promise.new());
		end);
	end);
	it("supplies a sensible tostring()", function ()
		local s = tostring(promise.new());
		assert.truthy(s:find("promise", 1, true));
		assert.truthy(s:find("pending", 1, true));
	end);
	it("notifies immediately for fulfilled promises", function ()
		local p = promise.new(function (resolve)
			resolve("foo");
		end);
		local cb = spy.new(function (v)
			assert.equal("foo", v);
		end);
		p:next(cb);
		assert.spy(cb).was_called(1);
	end);
	it("notifies on fulfillment of pending promises", function ()
		local r;
		local p = promise.new(function (resolve)
			r = resolve;
		end);
		local cb = spy.new(function (v)
			assert.equal("foo", v);
		end);
		p:next(cb);
		assert.spy(cb).was_called(0);
		r("foo");
		assert.spy(cb).was_called(1);
	end);
	it("ignores resolve/reject of settled promises", function ()
		local res, rej;
		local p = promise.new(function (resolve, reject)
			res, rej = resolve, reject;
		end);
		local cb = spy.new(function (v)
			assert.equal("foo", v);
		end);
		p:next(cb, cb);
		assert.spy(cb).was_called(0);
		res("foo");
		assert.spy(cb).was_called(1);
		rej("bar");
		assert.spy(cb).was_called(1);
		rej(promise.resolve("bar"));
		assert.spy(cb).was_called(1);
		res(promise.reject("bar"));
		assert.spy(cb).was_called(1);
		res(promise.resolve("bar"));
		assert.spy(cb).was_called(1);
	end);
	it("allows chaining :next() calls", function ()
		local r;
		local result;
		local p = promise.new(function (resolve)
			r = resolve;
		end);
		local cb1 = spy.new(function (v)
			assert.equal("foo", v);
			return "bar";
		end);
		local cb2 = spy.new(function (v)
			assert.equal("bar", v);
			result = v;
		end);
		p:next(cb1):next(cb2);
		assert.spy(cb1).was_called(0);
		assert.spy(cb2).was_called(0);
		r("foo");
		assert.spy(cb1).was_called(1);
		assert.spy(cb2).was_called(1);
		assert.equal("bar", result);
	end);
	it("supports multiple :next() calls on the same promise", function ()
		local r;
		local result;
		local p = promise.new(function (resolve)
			r = resolve;
		end);
		local cb1 = spy.new(function (v)
			assert.equal("foo", v);
			result = v;
		end);
		local cb2 = spy.new(function (v)
			assert.equal("foo", v);
			result = v;
		end);
		p:next(cb1);
		p:next(cb2);
		assert.spy(cb1).was_called(0);
		assert.spy(cb2).was_called(0);
		r("foo");
		assert.spy(cb1).was_called(1);
		assert.spy(cb2).was_called(1);
		assert.equal("foo", result);
	end);
	it("automatically rejects on error", function ()
		local r;
		local p = promise.new(function (resolve)
			r = resolve;
			error("oh no");
		end);
		local cb = spy.new(function () end);
		local err_cb = spy.new(function (v)
			assert.equal("oh no", v);
		end);
		p:next(cb, err_cb);
		assert.spy(cb).was_called(0);
		assert.spy(err_cb).was_called(1);
		r("foo");
		assert.spy(cb).was_called(0);
		assert.spy(err_cb).was_called(1);
	end);
	it("supports reject()", function ()
		local r, result;
		local p = promise.new(function (resolve, reject)
			r = reject;
		end);
		local cb = spy.new(function () end);
		local err_cb = spy.new(function (v)
			result = v;
			assert.equal("oh doh", v);
		end);
		p:next(cb, err_cb);
		assert.spy(cb).was_called(0);
		assert.spy(err_cb).was_called(0);
		r("oh doh");
		assert.spy(cb).was_called(0);
		assert.spy(err_cb).was_called(1);
		assert.equal("oh doh", result);
	end);
	it("supports chaining of rejected promises", function ()
		local r, result;
		local p = promise.new(function (resolve, reject)
			r = reject;
		end);
		local cb = spy.new(function () end);
		local err_cb = spy.new(function (v)
			result = v;
			assert.equal("oh doh", v);
			return "ok"
		end);
		local cb2 = spy.new(function (v)
			result = v;
		end);
		local err_cb2 = spy.new(function () end);
		p:next(cb, err_cb):next(cb2, err_cb2)
		assert.spy(cb).was_called(0);
		assert.spy(err_cb).was_called(0);
		assert.spy(cb2).was_called(0);
		assert.spy(err_cb2).was_called(0);
		r("oh doh");
		assert.spy(cb).was_called(0);
		assert.spy(err_cb).was_called(1);
		assert.spy(cb2).was_called(1);
		assert.spy(err_cb2).was_called(0);
		assert.equal("ok", result);
	end);

	it("propagates errors down the chain, even when some handlers are not provided", function ()
		local r, result;
		local test_error = {};
		local p = promise.new(function (resolve, reject)
			r = reject;
		end);
		local cb = spy.new(function () end);
		local err_cb = spy.new(function (e) result = e end);
		local p2 = p:next(function () error(test_error) end);
		local p3 = p2:next(cb)
		p3:catch(err_cb);
		assert.spy(cb).was_called(0);
		assert.spy(err_cb).was_called(0);
		r("oh doh");
		assert.spy(cb).was_called(0);
		assert.spy(err_cb).was_called(1);
		assert.spy(err_cb).was_called_with("oh doh");
		assert.equal("oh doh", result);
	end);

	it("propagates values down the chain, even when some handlers are not provided", function ()
		local r;
		local p = promise.new(function (resolve, reject)
			r = resolve;
		end);
		local cb = spy.new(function () end);
		local err_cb = spy.new(function () end);
		local p2 = p:next(function (v) return v; end);
		local p3 = p2:catch(err_cb)
		p3:next(cb);
		assert.spy(cb).was_called(0);
		assert.spy(err_cb).was_called(0);
		r(1337);
		assert.spy(cb).was_called(1);
		assert.spy(cb).was_called_with(1337);
		assert.spy(err_cb).was_called(0);
	end);

	it("fulfilled promises do not call error handlers and do propagate value", function ()
		local p = promise.resolve("foo");
		local cb = spy.new(function () end);
		local p2 = p:catch(cb);
		assert.spy(cb).was_called(0);

		local cb2 = spy.new(function () end);
		p2:catch(cb2);
		assert.spy(cb2).was_called(0);
	end);

	it("rejected promises do not call fulfilled handlers and do propagate reason", function ()
		local p = promise.reject("foo");
		local cb = spy.new(function () end);
		local p2 = p:next(cb);
		assert.spy(cb).was_called(0);

		local cb2 = spy.new(function () end);
		local cb2_err = spy.new(function () end);
		p2:next(cb2, cb2_err);
		assert.spy(cb2).was_called(0);
		assert.spy(cb2_err).was_called(1);
		assert.spy(cb2_err).was_called_with("foo");
	end);

	describe("allows callbacks to return", function ()
		it("pending promises", function ()
			local r;
			local p = promise.resolve()
			local cb = spy.new(function ()
				return promise.new(function (resolve)
					r = resolve;
				end);
			end);
			local cb2 = spy.new(function () end);
			p:next(cb):next(cb2);
			assert.spy(cb).was_called(1);
			assert.spy(cb2).was_called(0);
			r("hello");
			assert.spy(cb).was_called(1);
			assert.spy(cb2).was_called(1);
			assert.spy(cb2).was_called_with("hello");
		end);

		it("resolved promises", function ()
			local p = promise.resolve()
			local cb = spy.new(function ()
				return promise.resolve("hello");
			end);
			local cb2 = spy.new(function () end);
			p:next(cb):next(cb2);
			assert.spy(cb).was_called(1);
			assert.spy(cb2).was_called(1);
			assert.spy(cb2).was_called_with("hello");
		end);

		it("rejected promises", function ()
			local p = promise.resolve()
			local cb = spy.new(function ()
				return promise.reject("hello");
			end);
			local cb2 = spy.new(function ()
				return promise.reject("goodbye");
			end);
			local cb3 = spy.new(function () end);
			p:next(cb):catch(cb2):catch(cb3);
			assert.spy(cb).was_called(1);
			assert.spy(cb2).was_called(1);
			assert.spy(cb2).was_called_with("hello");
			assert.spy(cb3).was_called(1);
			assert.spy(cb3).was_called_with("goodbye");
		end);

		it("ordinary values", function ()
			local p = promise.resolve()
			local cb = spy.new(function ()
				return "hello"
			end);
			local cb2 = spy.new(function () end);
			p:next(cb):next(cb2);
			assert.spy(cb).was_called(1);
			assert.spy(cb2).was_called(1);
			assert.spy(cb2).was_called_with("hello");
		end);

		it("nil", function ()
			local p = promise.resolve()
			local cb = spy.new(function ()
				return
			end);
			local cb2 = spy.new(function () end);
			p:next(cb):next(cb2);
			assert.spy(cb).was_called(1);
			assert.spy(cb2).was_called(1);
			assert.spy(cb2).was_called_with(nil);
		end);
	end);

	describe("race()", function ()
		it("works with fulfilled promises", function ()
			local p1, p2 = promise.resolve("yep"), promise.resolve("nope");
			local p = promise.race({ p1, p2 });
			local result;
			p:next(function (v)
				result = v;
			end);
			assert.equal("yep", result);
		end);
		it("works with pending promises", function ()
			local r1, r2;
			local p1, p2 = promise.new(function (resolve) r1 = resolve end), promise.new(function (resolve) r2 = resolve end);
			local p = promise.race({ p1, p2 });

			local result;
			local cb = spy.new(function (v)
				result = v;
			end);
			p:next(cb);
			assert.spy(cb).was_called(0);
			r2("yep");
			r1("nope");
			assert.spy(cb).was_called(1);
			assert.equal("yep", result);
		end);
	end);
	describe("all()", function ()
		it("works with fulfilled promises", function ()
			local p1, p2 = promise.resolve("yep"), promise.resolve("nope");
			local p = promise.all({ p1, p2 });
			local result;
			p:next(function (v)
				result = v;
			end);
			assert.same({ "yep", "nope" }, result);
		end);
		it("works with pending promises", function ()
			local r1, r2;
			local p1, p2 = promise.new(function (resolve) r1 = resolve end), promise.new(function (resolve) r2 = resolve end);
			local p = promise.all({ p1, p2 });

			local result;
			local cb = spy.new(function (v)
				result = v;
			end);
			p:next(cb);
			assert.spy(cb).was_called(0);
			r2("yep");
			assert.spy(cb).was_called(0);
			r1("nope");
			assert.spy(cb).was_called(1);
			assert.same({ "nope", "yep" }, result);
		end);
		it("rejects if any promise rejects", function ()
			local r1, r2;
			local p1 = promise.new(function (resolve, reject) r1 = reject end);
			local p2 = promise.new(function (resolve, reject) r2 = reject end);
			local p = promise.all({ p1, p2 });

			local result;
			local cb = spy.new(function (v)
				result = v;
			end);
			local cb_err = spy.new(function (v)
				result = v;
			end);
			p:next(cb, cb_err);
			assert.spy(cb).was_called(0);
			assert.spy(cb_err).was_called(0);
			r2("fail");
			assert.spy(cb).was_called(0);
			assert.spy(cb_err).was_called(1);
			r1("nope");
			assert.spy(cb).was_called(0);
			assert.spy(cb_err).was_called(1);
			assert.equal("fail", result);
		end);
		it("works with non-numeric keys", function ()
			local r1, r2;
			local p1, p2 = promise.new(function (resolve) r1 = resolve end), promise.new(function (resolve) r2 = resolve end);
			local p = promise.all({ [true] = p1, [false] = p2 });

			local result;
			local cb = spy.new(function (v)
				result = v;
			end);
			p:next(cb);
			assert.spy(cb).was_called(0);
			r2("yep");
			assert.spy(cb).was_called(0);
			r1("nope");
			assert.spy(cb).was_called(1);
			assert.same({ [true] = "nope", [false] = "yep" }, result);
		end);
		it("passes through non-promise values", function ()
			local r1;
			local p1 = promise.new(function (resolve) r1 = resolve end);
			local p = promise.all({ [true] = p1, [false] = "yep" });

			local result;
			local cb = spy.new(function (v)
				result = v;
			end);
			p:next(cb);
			assert.spy(cb).was_called(0);
			r1("nope");
			assert.spy(cb).was_called(1);
			assert.same({ [true] = "nope", [false] = "yep" }, result);
		end);
	end);
	describe("all_settled()", function ()
		it("works with fulfilled promises", function ()
			local p1, p2 = promise.resolve("yep"), promise.resolve("nope");
			local p = promise.all_settled({ p1, p2 });
			local result;
			p:next(function (v)
				result = v;
			end);
			assert.same({
				{ status = "fulfilled", value = "yep" };
				{ status = "fulfilled", value = "nope" };
			}, result);
		end);
		it("works with pending promises", function ()
			local r1, r2;
			local p1, p2 = promise.new(function (resolve) r1 = resolve end), promise.new(function (resolve) r2 = resolve end);
			local p = promise.all_settled({ p1, p2 });

			local result;
			local cb = spy.new(function (v)
				result = v;
			end);
			p:next(cb);
			assert.spy(cb).was_called(0);
			r2("yep");
			assert.spy(cb).was_called(0);
			r1("nope");
			assert.spy(cb).was_called(1);
			assert.same({
				{ status = "fulfilled", value = "nope" };
				{ status = "fulfilled", value = "yep" };
			}, result);
		end);
		it("works when some promises reject", function ()
			local r1, r2;
			local p1, p2 = promise.new(function (resolve) r1 = resolve end), promise.new(function (_, reject) r2 = reject end);
			local p = promise.all_settled({ p1, p2 });

			local result;
			local cb = spy.new(function (v)
				result = v;
			end);
			p:next(cb);
			assert.spy(cb).was_called(0);
			r2("this fails");
			assert.spy(cb).was_called(0);
			r1("this succeeds");
			assert.spy(cb).was_called(1);
			assert.same({
				{ status = "fulfilled", value = "this succeeds" };
				{ status = "rejected", reason = "this fails" };
			}, result);
		end);
		it("works when all promises reject", function ()
			local r1, r2;
			local p1, p2 = promise.new(function (_, reject) r1 = reject end), promise.new(function (_, reject) r2 = reject end);
			local p = promise.all_settled({ p1, p2 });

			local result;
			local cb = spy.new(function (v)
				result = v;
			end);
			p:next(cb);
			assert.spy(cb).was_called(0);
			r2("this fails");
			assert.spy(cb).was_called(0);
			r1("this fails too");
			assert.spy(cb).was_called(1);
			assert.same({
				{ status = "rejected", reason = "this fails too" };
				{ status = "rejected", reason = "this fails" };
			}, result);
		end);
		it("works with non-numeric keys", function ()
			local r1, r2;
			local p1, p2 = promise.new(function (resolve) r1 = resolve end), promise.new(function (resolve) r2 = resolve end);
			local p = promise.all_settled({ foo = p1, bar = p2 });

			local result;
			local cb = spy.new(function (v)
				result = v;
			end);
			p:next(cb);
			assert.spy(cb).was_called(0);
			r2("yep");
			assert.spy(cb).was_called(0);
			r1("nope");
			assert.spy(cb).was_called(1);
			assert.same({
				foo = { status = "fulfilled", value = "nope" };
				bar = { status = "fulfilled", value = "yep" };
			}, result);
		end);
		it("passes through non-promise values", function ()
			local r1;
			local p1 = promise.new(function (resolve) r1 = resolve end);
			local p = promise.all_settled({ foo = p1, bar = "yep" });

			local result;
			local cb = spy.new(function (v)
				result = v;
			end);
			p:next(cb);
			assert.spy(cb).was_called(0);
			r1("nope");
			assert.spy(cb).was_called(1);
			assert.same({
				foo = { status = "fulfilled", value = "nope" };
				bar = "yep";
			}, result);
		end);
	end);
	describe("catch()", function ()
		it("works", function ()
			local result;
			local p = promise.new(function (resolve)
				error({ foo = true });
			end);
			local cb1 = spy.new(function (v)
				result = v;
			end);
			assert.spy(cb1).was_called(0);
			p:catch(cb1);
			assert.spy(cb1).was_called(1);
			assert.same({ foo = true }, result);
		end);
	end);
	describe("join()", function ()
		it("works", function ()
			local r1, r2;
			local res1, res2;
			local p1, p2 = promise.new(function (resolve) r1 = resolve end), promise.new(function (resolve) r2 = resolve end);

			local p = promise.join(function (_res1, _res2)
				res1, res2 = _res1, _res2;
				return promise.resolve("works");
			end, p1, p2);

			local result;
			local cb = spy.new(function (v)
				result = v;
			end);
			p:next(cb);
			assert.spy(cb).was_called(0);
			r2("yep");
			assert.spy(cb).was_called(0);
			r1("nope");
			assert.spy(cb).was_called(1);
			assert.same("works", result);
			assert.equals("nope", res1);
			assert.equals("yep", res2);
		end);
	end);
	it("promises may be resolved by other promises", function ()
		local r1, r2;
		local p1, p2 = promise.new(function (resolve) r1 = resolve end), promise.new(function (resolve) r2 = resolve end);

		local result;
		local cb = spy.new(function (v)
			result = v;
		end);
		p1:next(cb);
		assert.spy(cb).was_called(0);

		r1(p2);
		assert.spy(cb).was_called(0);
		r2("yep");
		assert.spy(cb).was_called(1);
		assert.equal("yep", result);
	end);
	describe("reject()", function ()
		it("returns a rejected promise", function ()
			local p = promise.reject("foo");
			local cb = spy.new(function () end);
			p:catch(cb);
			assert.spy(cb).was_called(1);
			assert.spy(cb).was_called_with("foo");
		end);
		it("returns a rejected promise and does not call on_fulfilled", function ()
			local p = promise.reject("foo");
			local cb = spy.new(function () end);
			p:next(cb);
			assert.spy(cb).was_called(0);
		end);
	end);
	describe("finally()", function ()
		local p, p2, resolve, reject, on_finally;
		before_each(function ()
			p = promise.new(function (_resolve, _reject)
				resolve, reject = _resolve, _reject;
			end);
			on_finally = spy.new(function () end);
			p2 = p:finally(on_finally);
		end);
		it("runs when a promise is resolved", function ()
			assert.spy(on_finally).was_called(0);
			resolve("foo");
			assert.spy(on_finally).was_called(1);
			assert.spy(on_finally).was_not_called_with("foo");
		end);
		it("runs when a promise is rejected", function ()
			assert.spy(on_finally).was_called(0);
			reject("foo");
			assert.spy(on_finally).was_called(1);
			assert.spy(on_finally).was_not_called_with("foo");
		end);
		it("returns a promise that fulfills with the original value", function ()
			local cb2 = spy.new(function () end);
			p2:next(cb2);
			assert.spy(on_finally).was_called(0);
			assert.spy(cb2).was_called(0);
			resolve("foo");
			assert.spy(on_finally).was_called(1);
			assert.spy(cb2).was_called(1);
			assert.spy(on_finally).was_not_called_with("foo");
			assert.spy(cb2).was_called_with("foo");
		end);
		it("returns a promise that rejects with the original error", function ()
			local on_finally_err = spy.new(function () end);
			local on_finally_ok = spy.new(function () end);
			p2:catch(on_finally_err);
			p2:next(on_finally_ok);
			assert.spy(on_finally).was_called(0);
			assert.spy(on_finally_err).was_called(0);
			reject("foo");
			assert.spy(on_finally).was_called(1);
			-- Since the original promise was rejected, the finally promise should also be
			assert.spy(on_finally_ok).was_called(0);
			assert.spy(on_finally_err).was_called(1);
			assert.spy(on_finally).was_not_called_with("foo");
			assert.spy(on_finally_err).was_called_with("foo");
		end);
		it("returns a promise that rejects with an uncaught error inside on_finally", function ()
			p = promise.new(function (_resolve, _reject)
				resolve, reject = _resolve, _reject;
			end);
			local test_error = {};
			on_finally = spy.new(function () error(test_error) end);
			p2 = p:finally(on_finally);

			local on_finally_err = spy.new(function () end);
			p2:catch(on_finally_err);
			assert.spy(on_finally).was_called(0);
			assert.spy(on_finally_err).was_called(0);
			reject("foo");
			assert.spy(on_finally).was_called(1);
			assert.spy(on_finally_err).was_called(1);
			assert.spy(on_finally).was_not_called_with("foo");
			assert.spy(on_finally).was_not_called_with(test_error);
			assert.spy(on_finally_err).was_called_with(test_error);
		end);
	end);
	describe("try()", function ()
		it("works with functions that return a promise", function ()
			local resolve;
			local p = promise.try(function ()
				return promise.new(function (_resolve)
					resolve = _resolve;
				end);
			end);
			assert.is_function(resolve);
			local on_resolved = spy.new(function () end);
			p:next(on_resolved);
			assert.spy(on_resolved).was_not_called();
			resolve("foo");
			assert.spy(on_resolved).was_called_with("foo");
		end);

		it("works with functions that return a value", function ()
			local p = promise.try(function ()
				return "foo";
			end);
			local on_resolved = spy.new(function () end);
			p:next(on_resolved);
			assert.spy(on_resolved).was_called_with("foo");
		end);

		it("works with functions that return a promise that rejects", function ()
			local reject;
			local p = promise.try(function ()
				return promise.new(function (_, _reject)
					reject = _reject;
				end);
			end);
			assert.is_function(reject);
			local on_rejected = spy.new(function () end);
			p:catch(on_rejected);
			assert.spy(on_rejected).was_not_called();
			reject("foo");
			assert.spy(on_rejected).was_called_with("foo");
		end);

		it("works with functions that throw errors", function ()
			local test_error = {};
			local p = promise.try(function ()
				error(test_error);
			end);
			local on_rejected = spy.new(function () end);
			p:catch(on_rejected);
			assert.spy(on_rejected).was_called(1);
			assert.spy(on_rejected).was_called_with(test_error);
		end);
	end);
	describe("set_nexttick()", function ()
		it("works", function ()
			local next_tick = spy.new(function (f)
				f();
			end)
			local cb = spy.new(function () end);
			promise.set_nexttick(next_tick);
			promise.new(function (y, _)
				y("okay");
			end):next(cb);
			assert.spy(next_tick).was.called();
			assert.spy(cb).was.called_with("okay");
		end);
	end)
end);
