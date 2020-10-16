local dbg = require "util.debug";

describe("util.debug", function ()
	describe("traceback()", function ()
		it("works", function ()
			local tb = dbg.traceback();
			assert.is_string(tb);
		end);
	end);
	describe("get_traceback_table()", function ()
		it("works", function ()
			local count = 0;
			-- MUST stay in sync with the line numbers of these functions:
			local f1_defined, f3_defined = 43, 15;
			local function f3(f3_param) --luacheck: ignore 212/f3_param
				count = count + 1;

				for i = 1, 2 do
					local tb = dbg.get_traceback_table(i == 1 and coroutine.running() or nil, 0);
					assert.is_table(tb);
					--print(dbg.traceback(), "\n\n\n", require "util.serialization".serialize(tb, { fatal = false, unquoted = true}));
					local found_f1, found_f3;
					for _, frame in ipairs(tb) do
						if frame.info.linedefined == f1_defined then
							assert.equal(0, #frame.locals);
							assert.equal("f2", frame.upvalues[1].name);
							assert.equal("f1_upvalue", frame.upvalues[2].name);
							found_f1 = true;
						elseif frame.info.linedefined == f3_defined then
							assert.equal("f3_param", frame.locals[1].name);
							found_f3 = true;
						end
					end
					assert.is_true(found_f1);
					assert.is_true(found_f3);
				end
			end
			local function f2()
				local f2_local = "hello";
				return f3(f2_local);
			end
			local f1_upvalue = "upvalue1";
			local function f1()
				f2(f1_upvalue);
			end

			-- ok/err are caught and re-thrown so that
			-- busted gets to handle them in its own way
			local ok, err;
			local function hook()
				debug.sethook();
				ok, err = pcall(f1);
			end

			-- Test the traceback is correct in various
			-- types of caller environments

			-- From a Lua hook
			debug.sethook(hook, "crl", 1);
			local a = string.sub("abcdef", 3, 4);
			assert.equal("cd", a);
			debug.sethook();
			assert.equal(1, count);

			if not ok then
				error(err);
			end
			ok, err = nil, nil;

			-- From a signal handler (C hook)
			require "util.signal".signal("SIGUSR1", hook);
			require "util.signal".raise("SIGUSR1");
			assert.equal(2, count);

			if not ok then
				error(err);
			end
			ok, err = nil, nil;

			-- Inside a coroutine
			local co = coroutine.create(function ()
				hook();
			end);
			coroutine.resume(co);

			if not ok then
				error(err);
			end

			assert.equal(3, count);
		end);
	end);
end);
