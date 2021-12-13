local format = require "util.format".format;
-- There are eight basic types in Lua:
-- nil, boolean, number, string, function, userdata, thread, and table

describe("util.format", function()
	describe("#format()", function()
		it("should work", function()
			assert.equal("hello", format("%s", "hello"));
			assert.equal("(nil)", format("%s"));
			assert.equal("(nil)", format("%d"));
			assert.equal("(nil)", format("%q"));
			assert.equal(" [(nil)]", format("", nil));
			assert.equal("true", format("%s", true));
			assert.equal("[true]", format("%d", true));
			assert.equal("% [true]", format("%%", true));
			assert.equal("{ }", format("%q", { }));
			assert.equal("[1.5]", format("%d", 1.5));
			assert.equal("[7.3786976294838e+19]", format("%d", 73786976294838206464));
		end);

		it("escapes ascii control stuff", function ()
			assert.equal("␁", format("%s", "\1"));
			assert.equal("[␁]", format("%d", "\1"));
		end);

		it("escapes invalid UTF-8", function ()
			assert.equal("\"Hello w\\195rld\"", format("%s", "Hello w\195rld"));
		end);

		if _VERSION >= "Lua 5.4" then
			it("handles %p formats", function ()
				assert.matches("a 0x%x+ b", format("%s %p %s", "a", {}, "b"));
			end)
		else
			it("does something with %p formats", function ()
				assert.string(format("%p", {}));
			end)
		end

		-- Tests generated with loops!
		describe("nil", function ()
			describe("to %c", function ()
				it("works", function ()
					assert.equal("(nil)", format("%c", nil))
				end);
			end);

			describe("to %d", function ()
				it("works", function ()
					assert.equal("(nil)", format("%d", nil))
				end);
			end);

			describe("to %i", function ()
				it("works", function ()
					assert.equal("(nil)", format("%i", nil))
				end);
			end);

			describe("to %o", function ()
				it("works", function ()
					assert.equal("(nil)", format("%o", nil))
				end);
			end);

			describe("to %u", function ()
				it("works", function ()
					assert.equal("(nil)", format("%u", nil))
				end);
			end);

			describe("to %x", function ()
				it("works", function ()
					assert.equal("(nil)", format("%x", nil))
				end);
			end);

			describe("to %X", function ()
				it("works", function ()
					assert.equal("(nil)", format("%X", nil))
				end);
			end);

			describe("to %a", function ()
				it("works", function ()
					assert.equal("(nil)", format("%a", nil))
				end);
			end);

			describe("to %A", function ()
				it("works", function ()
					assert.equal("(nil)", format("%A", nil))
				end);
			end);

			describe("to %e", function ()
				it("works", function ()
					assert.equal("(nil)", format("%e", nil))
				end);
			end);

			describe("to %E", function ()
				it("works", function ()
					assert.equal("(nil)", format("%E", nil))
				end);
			end);

			describe("to %f", function ()
				it("works", function ()
					assert.equal("(nil)", format("%f", nil))
				end);
			end);

			describe("to %g", function ()
				it("works", function ()
					assert.equal("(nil)", format("%g", nil))
				end);
			end);

			describe("to %G", function ()
				it("works", function ()
					assert.equal("(nil)", format("%G", nil))
				end);
			end);

			describe("to %q", function ()
				it("works", function ()
					assert.equal("(nil)", format("%q", nil))
				end);
			end);

			describe("to %s", function ()
				it("works", function ()
					assert.equal("(nil)", format("%s", nil))
				end);
			end);

		end);

		describe("boolean", function ()
			describe("to %c", function ()
				it("works", function ()
					assert.equal("[true]", format("%c", true))
					assert.equal("[false]", format("%c", false))
				end);
			end);

			describe("to %d", function ()
				it("works", function ()
					assert.equal("[true]", format("%d", true))
					assert.equal("[false]", format("%d", false))
				end);
			end);

			describe("to %i", function ()
				it("works", function ()
					assert.equal("[true]", format("%i", true))
					assert.equal("[false]", format("%i", false))
				end);
			end);

			describe("to %o", function ()
				it("works", function ()
					assert.equal("[true]", format("%o", true))
					assert.equal("[false]", format("%o", false))
				end);
			end);

			describe("to %u", function ()
				it("works", function ()
					assert.equal("[true]", format("%u", true))
					assert.equal("[false]", format("%u", false))
				end);
			end);

			describe("to %x", function ()
				it("works", function ()
					assert.equal("[true]", format("%x", true))
					assert.equal("[false]", format("%x", false))
				end);
			end);

			describe("to %X", function ()
				it("works", function ()
					assert.equal("[true]", format("%X", true))
					assert.equal("[false]", format("%X", false))
				end);
			end);

			describe("to %a", function ()
				it("works", function ()
					assert.equal("[true]", format("%a", true))
					assert.equal("[false]", format("%a", false))
				end);
			end);

			describe("to %A", function ()
				it("works", function ()
					assert.equal("[true]", format("%A", true))
					assert.equal("[false]", format("%A", false))
				end);
			end);

			describe("to %e", function ()
				it("works", function ()
					assert.equal("[true]", format("%e", true))
					assert.equal("[false]", format("%e", false))
				end);
			end);

			describe("to %E", function ()
				it("works", function ()
					assert.equal("[true]", format("%E", true))
					assert.equal("[false]", format("%E", false))
				end);
			end);

			describe("to %f", function ()
				it("works", function ()
					assert.equal("[true]", format("%f", true))
					assert.equal("[false]", format("%f", false))
				end);
			end);

			describe("to %g", function ()
				it("works", function ()
					assert.equal("[true]", format("%g", true))
					assert.equal("[false]", format("%g", false))
				end);
			end);

			describe("to %G", function ()
				it("works", function ()
					assert.equal("[true]", format("%G", true))
					assert.equal("[false]", format("%G", false))
				end);
			end);

			describe("to %q", function ()
				it("works", function ()
					assert.equal("true", format("%q", true))
					assert.equal("false", format("%q", false))
				end);
			end);

			describe("to %s", function ()
				it("works", function ()
					assert.equal("true", format("%s", true))
					assert.equal("false", format("%s", false))
				end);
			end);

		end);

		describe("number", function ()
			describe("to %c", function ()
				it("works", function ()
					assert.equal("a", format("%c", 97))
					assert.equal("[1.5]", format("%c", 1.5))
					assert.equal("[7.3786976294838e+19]", format("%c", 73786976294838206464))
					assert.equal("[inf]", format("%c", math.huge))
				end);
			end);

			describe("to %d", function ()
				it("works", function ()
					assert.equal("97", format("%d", 97))
					assert.equal("-12345", format("%d", -12345))
					assert.equal("[1.5]", format("%d", 1.5))
					assert.equal("[7.3786976294838e+19]", format("%d", 73786976294838206464))
					assert.equal("[inf]", format("%d", math.huge))
					assert.equal("2147483647", format("%d", 2147483647))
				end);
			end);

			describe("to %i", function ()
				it("works", function ()
					assert.equal("97", format("%i", 97))
					assert.equal("-12345", format("%i", -12345))
					assert.equal("[1.5]", format("%i", 1.5))
					assert.equal("[7.3786976294838e+19]", format("%i", 73786976294838206464))
					assert.equal("[inf]", format("%i", math.huge))
					assert.equal("2147483647", format("%i", 2147483647))
				end);
			end);

			describe("to %o", function ()
				it("works", function ()
					assert.equal("141", format("%o", 97))
					assert.equal("[-12345]", format("%o", -12345))
					assert.equal("[1.5]", format("%o", 1.5))
					assert.equal("[7.3786976294838e+19]", format("%o", 73786976294838206464))
					assert.equal("[inf]", format("%o", math.huge))
					assert.equal("17777777777", format("%o", 2147483647))
				end);
			end);

			describe("to %u", function ()
				it("works", function ()
					assert.equal("97", format("%u", 97))
					assert.equal("[-12345]", format("%u", -12345))
					assert.equal("[1.5]", format("%u", 1.5))
					assert.equal("[7.3786976294838e+19]", format("%u", 73786976294838206464))
					assert.equal("[inf]", format("%u", math.huge))
					assert.equal("2147483647", format("%u", 2147483647))
				end);
			end);

			describe("to %x", function ()
				it("works", function ()
					assert.equal("61", format("%x", 97))
					assert.equal("[-12345]", format("%x", -12345))
					assert.equal("[1.5]", format("%x", 1.5))
					assert.equal("[7.3786976294838e+19]", format("%x", 73786976294838206464))
					assert.equal("[inf]", format("%x", math.huge))
					assert.equal("7fffffff", format("%x", 2147483647))
				end);
			end);

			describe("to %X", function ()
				it("works", function ()
					assert.equal("61", format("%X", 97))
					assert.equal("[-12345]", format("%X", -12345))
					assert.equal("[1.5]", format("%X", 1.5))
					assert.equal("[7.3786976294838e+19]", format("%X", 73786976294838206464))
					assert.equal("[inf]", format("%X", math.huge))
					assert.equal("7FFFFFFF", format("%X", 2147483647))
				end);
			end);

			if _VERSION > "Lua 5.1" then -- COMPAT no %a or %A in Lua 5.1
				describe("to %a", function ()
					it("works", function ()
						assert.equal("0x1.84p+6", format("%a", 97))
						assert.equal("-0x1.81c8p+13", format("%a", -12345))
						assert.equal("0x1.8p+0", format("%a", 1.5))
						assert.equal("0x1p+66", format("%a", 73786976294838206464))
						assert.equal("inf", format("%a", math.huge))
						assert.equal("0x1.fffffffcp+30", format("%a", 2147483647))
					end);
				end);

				describe("to %A", function ()
					it("works", function ()
						assert.equal("0X1.84P+6", format("%A", 97))
						assert.equal("-0X1.81C8P+13", format("%A", -12345))
						assert.equal("0X1.8P+0", format("%A", 1.5))
						assert.equal("0X1P+66", format("%A", 73786976294838206464))
						assert.equal("INF", format("%A", math.huge))
						assert.equal("0X1.FFFFFFFCP+30", format("%A", 2147483647))
					end);
				end);
			end

			describe("to %e", function ()
				it("works", function ()
					assert.equal("9.700000e+01", format("%e", 97))
					assert.equal("-1.234500e+04", format("%e", -12345))
					assert.equal("1.500000e+00", format("%e", 1.5))
					assert.equal("7.378698e+19", format("%e", 73786976294838206464))
					assert.equal("inf", format("%e", math.huge))
					assert.equal("2.147484e+09", format("%e", 2147483647))
				end);
			end);

			describe("to %E", function ()
				it("works", function ()
					assert.equal("9.700000E+01", format("%E", 97))
					assert.equal("-1.234500E+04", format("%E", -12345))
					assert.equal("1.500000E+00", format("%E", 1.5))
					assert.equal("7.378698E+19", format("%E", 73786976294838206464))
					assert.equal("INF", format("%E", math.huge))
					assert.equal("2.147484E+09", format("%E", 2147483647))
				end);
			end);

			describe("to %f", function ()
				it("works", function ()
					assert.equal("97.000000", format("%f", 97))
					assert.equal("-12345.000000", format("%f", -12345))
					assert.equal("1.500000", format("%f", 1.5))
					assert.equal("73786976294838206464.000000", format("%f", 73786976294838206464))
					assert.equal("inf", format("%f", math.huge))
					assert.equal("2147483647.000000", format("%f", 2147483647))
				end);
			end);

			describe("to %g", function ()
				it("works", function ()
					assert.equal("97", format("%g", 97))
					assert.equal("-12345", format("%g", -12345))
					assert.equal("1.5", format("%g", 1.5))
					assert.equal("7.3787e+19", format("%g", 73786976294838206464))
					assert.equal("inf", format("%g", math.huge))
					assert.equal("2.14748e+09", format("%g", 2147483647))
				end);
			end);

			describe("to %G", function ()
				it("works", function ()
					assert.equal("97", format("%G", 97))
					assert.equal("-12345", format("%G", -12345))
					assert.equal("1.5", format("%G", 1.5))
					assert.equal("7.3787E+19", format("%G", 73786976294838206464))
					assert.equal("INF", format("%G", math.huge))
					assert.equal("2.14748E+09", format("%G", 2147483647))
				end);
			end);

			describe("to %q", function ()
				it("works", function ()
					assert.equal("97", format("%q", 97))
					assert.equal("-12345", format("%q", -12345))
					assert.equal("1.5", format("%q", 1.5))
					assert.equal("7.37869762948382065e+19", format("%q", 73786976294838206464))
					assert.equal("(1/0)", format("%q", math.huge))
					assert.equal("2147483647", format("%q", 2147483647))
				end);
			end);

			describe("to %s", function ()
				it("works", function ()
					assert.equal("97", format("%s", 97))
					assert.equal("-12345", format("%s", -12345))
					assert.equal("1.5", format("%s", 1.5))
					assert.equal("7.3786976294838e+19", format("%s", 73786976294838206464))
					assert.equal("inf", format("%s", math.huge))
					assert.equal("2147483647", format("%s", 2147483647))
				end);
			end);

		end);

		describe("string", function ()
			describe("to %c", function ()
				it("works", function ()
					assert.equal("[hello]", format("%c", "hello"))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%c", "foo \001\002\003 bar"))
					assert.equal("[nödåtgärd]", format("%c", "n\195\182d\195\165tg\195\164rd"))
					assert.equal("\"n\\195\\182d\\195\\165tg\\195\"", format("%c", "n\195\182d\195\165tg\195"))
				end);
			end);

			describe("to %d", function ()
				it("works", function ()
					assert.equal("[hello]", format("%d", "hello"))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%d", "foo \001\002\003 bar"))
					assert.equal("[nödåtgärd]", format("%d", "n\195\182d\195\165tg\195\164rd"))
					assert.equal("\"n\\195\\182d\\195\\165tg\\195\"", format("%d", "n\195\182d\195\165tg\195"))
				end);
			end);

			describe("to %i", function ()
				it("works", function ()
					assert.equal("[hello]", format("%i", "hello"))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%i", "foo \001\002\003 bar"))
					assert.equal("[nödåtgärd]", format("%i", "n\195\182d\195\165tg\195\164rd"))
					assert.equal("\"n\\195\\182d\\195\\165tg\\195\"", format("%i", "n\195\182d\195\165tg\195"))
				end);
			end);

			describe("to %o", function ()
				it("works", function ()
					assert.equal("[hello]", format("%o", "hello"))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%o", "foo \001\002\003 bar"))
					assert.equal("[nödåtgärd]", format("%o", "n\195\182d\195\165tg\195\164rd"))
					assert.equal("\"n\\195\\182d\\195\\165tg\\195\"", format("%o", "n\195\182d\195\165tg\195"))
				end);
			end);

			describe("to %u", function ()
				it("works", function ()
					assert.equal("[hello]", format("%u", "hello"))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%u", "foo \001\002\003 bar"))
					assert.equal("[nödåtgärd]", format("%u", "n\195\182d\195\165tg\195\164rd"))
					assert.equal("\"n\\195\\182d\\195\\165tg\\195\"", format("%u", "n\195\182d\195\165tg\195"))
				end);
			end);

			describe("to %x", function ()
				it("works", function ()
					assert.equal("[hello]", format("%x", "hello"))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%x", "foo \001\002\003 bar"))
					assert.equal("[nödåtgärd]", format("%x", "n\195\182d\195\165tg\195\164rd"))
					assert.equal("\"n\\195\\182d\\195\\165tg\\195\"", format("%x", "n\195\182d\195\165tg\195"))
				end);
			end);

			describe("to %X", function ()
				it("works", function ()
					assert.equal("[hello]", format("%X", "hello"))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%X", "foo \001\002\003 bar"))
					assert.equal("[nödåtgärd]", format("%X", "n\195\182d\195\165tg\195\164rd"))
					assert.equal("\"n\\195\\182d\\195\\165tg\\195\"", format("%X", "n\195\182d\195\165tg\195"))
				end);
			end);

			describe("to %a", function ()
				it("works", function ()
					assert.equal("[hello]", format("%a", "hello"))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%a", "foo \001\002\003 bar"))
					assert.equal("[nödåtgärd]", format("%a", "n\195\182d\195\165tg\195\164rd"))
					assert.equal("\"n\\195\\182d\\195\\165tg\\195\"", format("%a", "n\195\182d\195\165tg\195"))
				end);
			end);

			describe("to %A", function ()
				it("works", function ()
					assert.equal("[hello]", format("%A", "hello"))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%A", "foo \001\002\003 bar"))
					assert.equal("[nödåtgärd]", format("%A", "n\195\182d\195\165tg\195\164rd"))
					assert.equal("\"n\\195\\182d\\195\\165tg\\195\"", format("%A", "n\195\182d\195\165tg\195"))
				end);
			end);

			describe("to %e", function ()
				it("works", function ()
					assert.equal("[hello]", format("%e", "hello"))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%e", "foo \001\002\003 bar"))
					assert.equal("[nödåtgärd]", format("%e", "n\195\182d\195\165tg\195\164rd"))
					assert.equal("\"n\\195\\182d\\195\\165tg\\195\"", format("%e", "n\195\182d\195\165tg\195"))
				end);
			end);

			describe("to %E", function ()
				it("works", function ()
					assert.equal("[hello]", format("%E", "hello"))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%E", "foo \001\002\003 bar"))
					assert.equal("[nödåtgärd]", format("%E", "n\195\182d\195\165tg\195\164rd"))
					assert.equal("\"n\\195\\182d\\195\\165tg\\195\"", format("%E", "n\195\182d\195\165tg\195"))
				end);
			end);

			describe("to %f", function ()
				it("works", function ()
					assert.equal("[hello]", format("%f", "hello"))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%f", "foo \001\002\003 bar"))
					assert.equal("[nödåtgärd]", format("%f", "n\195\182d\195\165tg\195\164rd"))
					assert.equal("\"n\\195\\182d\\195\\165tg\\195\"", format("%f", "n\195\182d\195\165tg\195"))
				end);
			end);

			describe("to %g", function ()
				it("works", function ()
					assert.equal("[hello]", format("%g", "hello"))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%g", "foo \001\002\003 bar"))
					assert.equal("[nödåtgärd]", format("%g", "n\195\182d\195\165tg\195\164rd"))
					assert.equal("\"n\\195\\182d\\195\\165tg\\195\"", format("%g", "n\195\182d\195\165tg\195"))
				end);
			end);

			describe("to %G", function ()
				it("works", function ()
					assert.equal("[hello]", format("%G", "hello"))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%G", "foo \001\002\003 bar"))
					assert.equal("[nödåtgärd]", format("%G", "n\195\182d\195\165tg\195\164rd"))
					assert.equal("\"n\\195\\182d\\195\\165tg\\195\"", format("%G", "n\195\182d\195\165tg\195"))
				end);
			end);

			describe("to %q", function ()
				it("works", function ()
					assert.equal("\"hello\"", format("%q", "hello"))
					assert.equal("\"foo \226\144\129\226\144\130\226\144\131 bar\"", format("%q", "foo \001\002\003 bar"))
					assert.equal("\"nödåtgärd\"", format("%q", "n\195\182d\195\165tg\195\164rd"))
					assert.equal("\"n\\195\\182d\\195\\165tg\\195\"", format("%q", "n\195\182d\195\165tg\195"))
				end);
			end);

			describe("to %s", function ()
				it("works", function ()
					assert.equal("hello", format("%s", "hello"))
					assert.equal("foo \226\144\129\226\144\130\226\144\131 bar", format("%s", "foo \001\002\003 bar"))
					assert.equal("nödåtgärd", format("%s", "n\195\182d\195\165tg\195\164rd"))
					assert.equal("\"n\\195\\182d\\195\\165tg\\195\"", format("%s", "n\195\182d\195\165tg\195"))
				end);
			end);

		end);

		describe("function", function ()
			describe("to %c", function ()
				it("works", function ()
					assert.matches("[function: 0[xX]%x+]", format("%c", function() end))
				end);
			end);

			describe("to %d", function ()
				it("works", function ()
					assert.matches("[function: 0[xX]%x+]", format("%d", function() end))
				end);
			end);

			describe("to %i", function ()
				it("works", function ()
					assert.matches("[function: 0[xX]%x+]", format("%i", function() end))
				end);
			end);

			describe("to %o", function ()
				it("works", function ()
					assert.matches("[function: 0[xX]%x+]", format("%o", function() end))
				end);
			end);

			describe("to %u", function ()
				it("works", function ()
					assert.matches("[function: 0[xX]%x+]", format("%u", function() end))
				end);
			end);

			describe("to %x", function ()
				it("works", function ()
					assert.matches("[function: 0[xX]%x+]", format("%x", function() end))
				end);
			end);

			describe("to %X", function ()
				it("works", function ()
					assert.matches("[function: 0[xX]%x+]", format("%X", function() end))
				end);
			end);

			describe("to %a", function ()
				it("works", function ()
					assert.matches("[function: 0[xX]%x+]", format("%a", function() end))
				end);
			end);

			describe("to %A", function ()
				it("works", function ()
					assert.matches("[function: 0[xX]%x+]", format("%A", function() end))
				end);
			end);

			describe("to %e", function ()
				it("works", function ()
					assert.matches("[function: 0[xX]%x+]", format("%e", function() end))
				end);
			end);

			describe("to %E", function ()
				it("works", function ()
					assert.matches("[function: 0[xX]%x+]", format("%E", function() end))
				end);
			end);

			describe("to %f", function ()
				it("works", function ()
					assert.matches("[function: 0[xX]%x+]", format("%f", function() end))
				end);
			end);

			describe("to %g", function ()
				it("works", function ()
					assert.matches("[function: 0[xX]%x+]", format("%g", function() end))
				end);
			end);

			describe("to %G", function ()
				it("works", function ()
					assert.matches("[function: 0[xX]%x+]", format("%G", function() end))
				end);
			end);

			describe("to %q", function ()
				it("works", function ()
					assert.matches('{__type="function",__error="fail"}', format("%q", function() end))
				end);
			end);

			describe("to %s", function ()
				it("works", function ()
					assert.matches("function: 0[xX]%x+", format("%s", function() end))
				end);
			end);

		end);

		describe("thread", function ()
			describe("to %c", function ()
				it("works", function ()
					assert.matches("[thread: 0[xX]%x+]", format("%c", coroutine.create(function() end)))
				end);
			end);

			describe("to %d", function ()
				it("works", function ()
					assert.matches("[thread: 0[xX]%x+]", format("%d", coroutine.create(function() end)))
				end);
			end);

			describe("to %i", function ()
				it("works", function ()
					assert.matches("[thread: 0[xX]%x+]", format("%i", coroutine.create(function() end)))
				end);
			end);

			describe("to %o", function ()
				it("works", function ()
					assert.matches("[thread: 0[xX]%x+]", format("%o", coroutine.create(function() end)))
				end);
			end);

			describe("to %u", function ()
				it("works", function ()
					assert.matches("[thread: 0[xX]%x+]", format("%u", coroutine.create(function() end)))
				end);
			end);

			describe("to %x", function ()
				it("works", function ()
					assert.matches("[thread: 0[xX]%x+]", format("%x", coroutine.create(function() end)))
				end);
			end);

			describe("to %X", function ()
				it("works", function ()
					assert.matches("[thread: 0[xX]%x+]", format("%X", coroutine.create(function() end)))
				end);
			end);

			describe("to %a", function ()
				it("works", function ()
					assert.matches("[thread: 0[xX]%x+]", format("%a", coroutine.create(function() end)))
				end);
			end);

			describe("to %A", function ()
				it("works", function ()
					assert.matches("[thread: 0[xX]%x+]", format("%A", coroutine.create(function() end)))
				end);
			end);

			describe("to %e", function ()
				it("works", function ()
					assert.matches("[thread: 0[xX]%x+]", format("%e", coroutine.create(function() end)))
				end);
			end);

			describe("to %E", function ()
				it("works", function ()
					assert.matches("[thread: 0[xX]%x+]", format("%E", coroutine.create(function() end)))
				end);
			end);

			describe("to %f", function ()
				it("works", function ()
					assert.matches("[thread: 0[xX]%x+]", format("%f", coroutine.create(function() end)))
				end);
			end);

			describe("to %g", function ()
				it("works", function ()
					assert.matches("[thread: 0[xX]%x+]", format("%g", coroutine.create(function() end)))
				end);
			end);

			describe("to %G", function ()
				it("works", function ()
					assert.matches("[thread: 0[xX]%x+]", format("%G", coroutine.create(function() end)))
				end);
			end);

			describe("to %q", function ()
				it("works", function ()
					assert.matches('{__type="thread",__error="fail"}', format("%q", coroutine.create(function() end)))
				end);
			end);

			describe("to %s", function ()
				it("works", function ()
					assert.matches("thread: 0[xX]%x+", format("%s", coroutine.create(function() end)))
				end);
			end);

		end);

		describe("table", function ()
			describe("to %c", function ()
				it("works", function ()
					assert.matches("[table: 0[xX]%x+]", format("%c", { }))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%c", setmetatable({},{__tostring=function ()return "foo \1\2\3 bar"end})))
				end);
			end);

			describe("to %d", function ()
				it("works", function ()
					assert.matches("[table: 0[xX]%x+]", format("%d", { }))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%d", setmetatable({},{__tostring=function ()return "foo \1\2\3 bar"end})))
				end);
			end);

			describe("to %i", function ()
				it("works", function ()
					assert.matches("[table: 0[xX]%x+]", format("%i", { }))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%i", setmetatable({},{__tostring=function ()return "foo \1\2\3 bar"end})))
				end);
			end);

			describe("to %o", function ()
				it("works", function ()
					assert.matches("[table: 0[xX]%x+]", format("%o", { }))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%o", setmetatable({},{__tostring=function ()return "foo \1\2\3 bar"end})))
				end);
			end);

			describe("to %u", function ()
				it("works", function ()
					assert.matches("[table: 0[xX]%x+]", format("%u", { }))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%u", setmetatable({},{__tostring=function ()return "foo \1\2\3 bar"end})))
				end);
			end);

			describe("to %x", function ()
				it("works", function ()
					assert.matches("[table: 0[xX]%x+]", format("%x", { }))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%x", setmetatable({},{__tostring=function ()return "foo \1\2\3 bar"end})))
				end);
			end);

			describe("to %X", function ()
				it("works", function ()
					assert.matches("[table: 0[xX]%x+]", format("%X", { }))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%X", setmetatable({},{__tostring=function ()return "foo \1\2\3 bar"end})))
				end);
			end);

			describe("to %a", function ()
				it("works", function ()
					assert.matches("[table: 0[xX]%x+]", format("%a", { }))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%a", setmetatable({},{__tostring=function ()return "foo \1\2\3 bar"end})))
				end);
			end);

			describe("to %A", function ()
				it("works", function ()
					assert.matches("[table: 0[xX]%x+]", format("%A", { }))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%A", setmetatable({},{__tostring=function ()return "foo \1\2\3 bar"end})))
				end);
			end);

			describe("to %e", function ()
				it("works", function ()
					assert.matches("[table: 0[xX]%x+]", format("%e", { }))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%e", setmetatable({},{__tostring=function ()return "foo \1\2\3 bar"end})))
				end);
			end);

			describe("to %E", function ()
				it("works", function ()
					assert.matches("[table: 0[xX]%x+]", format("%E", { }))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%E", setmetatable({},{__tostring=function ()return "foo \1\2\3 bar"end})))
				end);
			end);

			describe("to %f", function ()
				it("works", function ()
					assert.matches("[table: 0[xX]%x+]", format("%f", { }))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%f", setmetatable({},{__tostring=function ()return "foo \1\2\3 bar"end})))
				end);
			end);

			describe("to %g", function ()
				it("works", function ()
					assert.matches("[table: 0[xX]%x+]", format("%g", { }))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%g", setmetatable({},{__tostring=function ()return "foo \1\2\3 bar"end})))
				end);
			end);

			describe("to %G", function ()
				it("works", function ()
					assert.matches("[table: 0[xX]%x+]", format("%G", { }))
					assert.equal("[foo \226\144\129\226\144\130\226\144\131 bar]", format("%G", setmetatable({},{__tostring=function ()return "foo \1\2\3 bar"end})))
				end);
			end);

			describe("to %q", function ()
				it("works", function ()
					assert.matches("{ }", format("%q", { }))
					assert.equal("{ }", format("%q", setmetatable({},{__tostring=function ()return "foo \1\2\3 bar"end})))
				end);
			end);

			describe("to %s", function ()
				it("works", function ()
					assert.matches("table: 0[xX]%x+", format("%s", { }))
					assert.equal("foo \226\144\129\226\144\130\226\144\131 bar", format("%s", setmetatable({},{__tostring=function ()return "foo \1\2\3 bar"end})))
				end);
			end);

		end);


	end);
end);
