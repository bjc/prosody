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

	describe("oauthbearer profile", function()
		local profile = {
			oauthbearer = function(_, token, _realm, _authzid)
				if token == "example-bearer-token" then
					return "user", true, {};
				else
					return nil, nil, {}
				end
			end;
		}

		it("works with OAUTHBEARER", function()
			local bearer = sasl.new("sasl.test", profile);

			assert.truthy(bearer:select("OAUTHBEARER"));
			assert.equals("success", bearer:process("n,,\1auth=Bearer example-bearer-token\1\1"));
			assert.equals("user", bearer.username);
		end)


		it("returns extras with OAUTHBEARER", function()
			local bearer = sasl.new("sasl.test", profile);

			assert.truthy(bearer:select("OAUTHBEARER"));
			local status, extra = bearer:process("n,,\1auth=Bearer unknown\1\1");
			assert.equals("challenge", status);
			assert.equals("{\"status\":\"invalid_token\"}", extra);
			assert.equals("failure", bearer:process("\1"));
		end)

	end)
end);

