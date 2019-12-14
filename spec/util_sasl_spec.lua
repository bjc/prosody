local sasl = require "util.sasl";

-- profile * mechanism
-- callbacks could use spies instead

describe("util.sasl", function ()
	describe("plain_test profile", function ()
		local profile = {
			plain_test = function (_, username, password, realm)
				assert.equals("user", username)
				assert.equals("pencil", password)
				assert.equals("sasl.test", realm)
				return true, true;
			end;
		};
		it("works with PLAIN", function ()
			local plain = sasl.new("sasl.test", profile);
			assert.truthy(plain:select("PLAIN"));
			assert.truthy(plain:process("\000user\000pencil"));
			assert.equals("user", plain.username);
		end);
	end);

	describe("plain profile", function ()
		local profile = {
			plain = function (_, username, realm)
				assert.equals("user", username)
				assert.equals("sasl.test", realm)
				return "pencil", true;
			end;
		};

		it("works with PLAIN", function ()
			local plain = sasl.new("sasl.test", profile);
			assert.truthy(plain:select("PLAIN"));
			assert.truthy(plain:process("\000user\000pencil"));
			assert.equals("user", plain.username);
		end);

		-- TODO SCRAM
	end);
end);

