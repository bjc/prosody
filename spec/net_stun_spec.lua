local hex = require "util.hex";

local function parse(pkt_desc)
	local result = {};
	for line in pkt_desc:gmatch("([^\n]+)\n") do
		local b1, b2, b3, b4 = line:match("^%s*(%x%x) (%x%x) (%x%x) (%x%x)%s");
		if b1 then
			table.insert(result, b1);
			table.insert(result, b2);
			table.insert(result, b3);
			table.insert(result, b4);
		end
	end
	return hex.decode(table.concat(result));
end

local sample_packet = parse[[
      00 01 00 60     Request type and message length
      21 12 a4 42     Magic cookie
      78 ad 34 33  }
      c6 ad 72 c0  }  Transaction ID
      29 da 41 2e  }
      00 06 00 12     USERNAME attribute header
      e3 83 9e e3  }
      83 88 e3 83  }
      aa e3 83 83  }  Username value (18 bytes) and padding (2 bytes)
      e3 82 af e3  }
      82 b9 00 00  }
      00 15 00 1c     NONCE attribute header
      66 2f 2f 34  }
      39 39 6b 39  }
      35 34 64 36  }
      4f 4c 33 34  }  Nonce value
      6f 4c 39 46  }
      53 54 76 79  }
      36 34 73 41  }
      00 14 00 0b     REALM attribute header
      65 78 61 6d  }
      70 6c 65 2e  }  Realm value (11 bytes) and padding (1 byte)
      6f 72 67 00  }
      00 08 00 14     MESSAGE-INTEGRITY attribute header
      f6 70 24 65  }
      6d d6 4a 3e  }
      02 b8 e0 71  }  HMAC-SHA1 fingerprint
      2e 85 c9 a2  }
      8c a8 96 66  }
]];

describe("net.stun", function ()
	local stun = require "net.stun";

	it("works", function ()
		local packet = stun.new_packet();
		assert.is_string(packet:serialize());
	end);

	it("can decode the sample packet", function ()
		local packet = stun.new_packet():deserialize(sample_packet);
		assert(packet);
		local method, method_name = packet:get_method();
		assert.equal(1, method);
		assert.equal("binding", method_name);
		assert.equal("example.org", packet:get_attribute("realm"));
	end);

	it("can generate the sample packet", function ()
		-- These values, and the sample packet, come from RFC 5769 2.4
		local username = string.char(
			-- U+30DE KATAKANA LETTER MA
			0xE3, 0x83, 0x9E,
			-- U+30C8 KATAKANA LETTER TO
			0xE3, 0x83, 0x88,
			-- U+30EA KATAKANA LETTER RI
			0xE3, 0x83, 0xAA,
			-- U+30C3 KATAKANA LETTER SMALL TU
			0xE3, 0x83, 0x83,
			-- U+30AF KATAKANA LETTER KU
			0xE3, 0x82, 0xAF,
			-- U+30B9 KATAKANA LETTER SU
			0xE3, 0x82, 0xB9
		);

		--    Password:  "The<U+00AD>M<U+00AA>tr<U+2168>" and "TheMatrIX" (without
		--       quotes) respectively before and after SASLprep processing
		local password = "TheMatrIX";
		local realm = "example.org";

		local p3 = stun.new_packet("binding", "request");
		p3.transaction_id = hex.decode("78AD3433C6AD72C029DA412E");
		p3:add_attribute("username", username);
		p3:add_attribute("nonce", "f//499k954d6OL34oL9FSTvy64sA");
		p3:add_attribute("realm", realm);
		local key = stun.get_long_term_auth_key(realm, username, password);
		p3:add_message_integrity(key);
		assert.equal(sample_packet, p3:serialize());
	end);
end);
