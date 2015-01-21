
local lfs = require"lfs";

local hg = { };

function hg.check_id(path)
	if lfs.attributes(path, 'mode') ~= "directory" then
		return nil, "not a directory";
	end
	local hg_dirstate = io.open(path.."/.hg/dirstate");
	local hgid, hgrepo
	if hg_dirstate then
		hgid = ("%02x%02x%02x%02x%02x%02x"):format(hg_dirstate:read(6):byte(1, 6));
		hg_dirstate:close();
		local hg_changelog = io.open(path.."/.hg/store/00changelog.i");
		if hg_changelog then
			hg_changelog:seek("set", 0x20);
			hgrepo = ("%02x%02x%02x%02x%02x%02x"):format(hg_changelog:read(6):byte(1, 6));
			hg_changelog:close();
		end
	else
		local hg_archival,e = io.open(path.."/.hg_archival.txt");
		if hg_archival then
			local repo = hg_archival:read("*l");
			local node = hg_archival:read("*l");
			hg_archival:close()
			hgid = node and node:match("^node: (%x%x%x%x%x%x%x%x%x%x%x%x)")
			hgrepo = repo and repo:match("^repo: (%x%x%x%x%x%x%x%x%x%x%x%x)")
		end
	end
	return hgid, hgrepo;
end

return hg;
