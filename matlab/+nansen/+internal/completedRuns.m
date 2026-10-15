function done = completedRuns(folder, entityType)
%completedRuns For each entity key (runKeyId), the methods that completed on it and when they last did
%
%   done is a containers.Map from runKeyId to a containers.Map from method id
%   to finishedAt. Lines that cannot be read (a write cut short) are skipped.
%   As Python's nansen.runs.completed.
    done = containers.Map("KeyType", "char", "ValueType", "any");
    path = fullfile(folder, "runs", string(entityType) + ".runs.jsonl");
    if ~isfile(path)
        return
    end
    lines = splitlines(string(nansen.internal.readText(path)));
    lines = lines(strlength(strtrim(lines)) > 0);
    if isempty(lines)
        return
    end
    try
        runs = nansen.internal.asCellOfStructs(jsondecode(char("[" + strjoin(lines, ",") + "]")));
    catch
        runs = {};   % some line is broken: read them one by one
        for i = 1:numel(lines)
            try
                runs{end + 1} = jsondecode(char(lines(i))); %#ok<AGROW>
            catch
            end
        end
    end
    for i = 1:numel(runs)
        run = runs{i};
        if ~isstruct(run) || ~isfield(run, "schemaType") || string(run.schemaType) ~= "nansen.run" ...
                || ~isfield(run, "key") || ~isfield(run, "method") || ~isfield(run, "finishedAt")
            continue
        end
        id = nansen.internal.runKeyId(run.key);
        if ~isKey(done, id)
            done(id) = containers.Map("KeyType", "char", "ValueType", "any");
        end
        methods = done(id);   % a handle: changed in place
        methodId = char(run.method.id);
        finished = string(run.finishedAt);
        if ~isKey(methods, methodId) || finished > string(methods(methodId))
            methods(methodId) = char(finished);
        end
    end
end
