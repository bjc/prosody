#!/bin/bash

POLYGLOT=1--[===[

set -o pipefail

if [[ "$#" == "0" ]]; then
	echo "Lua mutation testing tool"
	echo
	echo "Usage:"
	echo "    $BASH_SOURCE MODULE_NAME SPEC_FILE"
	echo
	echo "Requires 'lua', 'ltokenp' and 'busted' in PATH"
	exit 1;
fi

MOD_NAME="$1"
MOD_FILE="$(lua "$BASH_SOURCE" resolve "$MOD_NAME")"

if [[ "$MOD_FILE" == "" || ! -f "$MOD_FILE" ]]; then
	echo "EE: Failed to locate module '$MOD_NAME' ($MOD_FILE)";
	exit 1;
fi

SPEC_FILE="$2"

if [[ "$SPEC_FILE" == "" ]]; then
	SPEC_FILE="spec/${MOD_NAME/./_}_spec.lua"
fi

if [[ "$SPEC_FILE" == "" || ! -f "$SPEC_FILE" ]]; then
	echo "EE: Failed to find test spec file ($SPEC_FILE)"
	exit 1;
fi

if ! busted "$SPEC_FILE"; then
	echo "EE: Tests fail on original source. Fix it"\!;
	exit 1;
fi

export MUTANT_N=0
LIVING_MUTANTS=0

FILE_PREFIX="${MOD_FILE%.*}.mutant-"
FILE_SUFFIX=".${MOD_FILE##*.}"

gen_mutant () {
	echo "Generating mutant $2 to $3..."
	ltokenp -s "$BASH_SOURCE" "$1" > "$3"
	return "$?"
}

# $1 = MOD_NAME, $2 = MUTANT_N, $3 = SPEC_FILE
test_mutant () {
	(
		ulimit -m 131072 # 128MB
		ulimit -t 16     # 16s
		ulimit -f 32768  # 128MB (?)
		exec busted --helper="$BASH_SOURCE" -Xhelper mutate="$1":"$2" "$3"
	) >/dev/null
	return "$?";
}

MUTANT_FILE="${FILE_PREFIX}${MUTANT_N}${FILE_SUFFIX}"

gen_mutant "$MOD_FILE" "$MUTANT_N" "$MUTANT_FILE"
while [[ "$?" == "0" ]]; do
	if ! test_mutant "$MOD_NAME" "$MUTANT_N" "$SPEC_FILE"; then
		echo "Tests successfully killed mutant $MUTANT_N";
		rm "$MUTANT_FILE";
	else
		echo "Mutant $MUTANT_N lives on"\!
		LIVING_MUTANTS=$((LIVING_MUTANTS+1))
	fi
	MUTANT_N=$((MUTANT_N+1))
	MUTANT_FILE="${FILE_PREFIX}${MUTANT_N}${FILE_SUFFIX}"
	gen_mutant "$MOD_FILE" "$MUTANT_N" "$MUTANT_FILE"
done

if [[ "$?" != "2" ]]; then
	echo "Failed: $?"
	exit "$?";
fi

MUTANT_SCORE="$(lua -e "print(('%0.2f'):format((1-($LIVING_MUTANTS/$MUTANT_N))*100))")"
if test -f mutant-scores.txt; then
	echo "$MOD_NAME $MUTANT_SCORE" >> mutant-scores.txt
fi
echo "$MOD_NAME: All $MUTANT_N mutants generated, $LIVING_MUTANTS survived (score: $MUTANT_SCORE%)"
rm "$MUTANT_FILE"; # Last file is always unmodified
exit 0;
]===]

-- busted helper that runs mutations
if arg then
	if arg[1] == "resolve" then
		local filename = package.searchpath(assert(arg[2], "no module name given"), package.path);
		if filename then
			print(filename);
		end
		os.exit(filename and 0 or 1);
	end
	local mutants = {};

	for i = 1, #arg do
		local opt = arg[i];
		print("LOAD", i, opt)
		local module_name, mutant_n = opt:match("^mutate=([^:]+):(%d+)");
		if module_name then
			mutants[module_name] = tonumber(mutant_n);
		end
	end

	local orig_lua_searcher = package.searchers[2];

	local function mutant_searcher(module_name)
		local mutant_n = mutants[module_name];
		if not mutant_n then
			return orig_lua_searcher(module_name);
		end
		local base_file, err = package.searchpath(module_name, package.path);
		if not base_file then
			return base_file, err;
		end
		local mutant_file = base_file:gsub("%.lua$", (".mutant-%d.lua"):format(mutant_n));
		return loadfile(mutant_file), mutant_file;
	end

	if next(mutants) then
		table.insert(package.searchers, 1, mutant_searcher);
	end
end

-- filter for ltokenp to mutate scripts
do
	local last_output = {};
	local function emit(...)
		last_output = {...};
		io.write(...)
		io.write(" ")
		return true;
	end

	local did_mutate = false;
	local count = -1;
	local threshold = tonumber(os.getenv("MUTANT_N")) or 0;
	local function should_mutate()
		count = count + 1;
		return count == threshold;
	end

	local function mutate(name, value)
		if name == "if" then
			-- Bypass conditionals
			if should_mutate() then
				return emit("if true or");
			elseif should_mutate() then
				return emit("if false and");
			end
		elseif name == "<integer>" then
			-- Introduce off-by-one errors
			if should_mutate() then
				return emit(("%d"):format(tonumber(value)+1));
			elseif should_mutate() then
				return emit(("%d"):format(tonumber(value)-1));
			end
		elseif name == "and" then
			if should_mutate() then
				return emit("or");
			end
		elseif name == "or" then
			if should_mutate() then
				return emit("and");
			end
		end
	end

	local current_line_n, current_line_input, current_line_output = 0, {}, {};
	function FILTER(line_n,token,name,value)
		if current_line_n ~= line_n then -- Finished a line, moving to the next?
			if did_mutate and did_mutate.line == current_line_n then
				-- The line we finished was mutated. Store the original and modified outputs.
				did_mutate.line_original_src = table.concat(current_line_input, " ");
				did_mutate.line_modified_src = table.concat(current_line_output, " ");
			end
			current_line_input = {};
			current_line_output = {};
		end
		current_line_n = line_n;
		if name == "<file>" then return; end
		if name == "<eof>" then
			if not did_mutate then
				return os.exit(2);
			else
				emit(("\n-- Mutated line %d (changed '%s' to '%s'):\n"):format(did_mutate.line, did_mutate.original, did_mutate.modified))
				emit(  ("--   Original: %s\n"):format(did_mutate.line_original_src))
				emit(  ("--   Modified: %s\n"):format(did_mutate.line_modified_src));
				return;
			end
		end
		if name == "<string>" then
			value = string.format("%q",value);
		end
		if mutate(name, value) then
			did_mutate = {
				original = value;
				modified = table.concat(last_output);
				line = line_n;
			};
		else
			emit(value);
		end
		table.insert(current_line_input, value);
		table.insert(current_line_output, table.concat(last_output));
	end
end

