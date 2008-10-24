
local softreq = function (...) return select(2, pcall(require, ...)); end
local error = error;

module "hashes"

local md5 = softreq("md5");
if md5 then
	if md5.digest then
		local md5_digest = md5.digest;
		local sha1_digest = sha1.digest;
		function _M.md5(input)
			return md5_digest(input);
		end
		function _M.sha1(input)
			return sha1_digest(input);
		end
	elseif md5.sumhexa then
		local md5_sumhexa = md5.sumhexa;
		function _M.md5(input)
			return md5_sumhexa(input);
		end
	else
		error("md5 library found, but unrecognised... no hash functions will be available", 0);
	end
end

return _M;
