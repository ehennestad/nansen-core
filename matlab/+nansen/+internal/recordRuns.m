function recordRuns(folder, methodId, methodVersion, entities, taskId, mark)
%recordRuns Append to the run journal that a method completed on each of the entities
%
%   nansen.internal.recordRuns(projectFolder, methodId, methodVersion,
%   entities, taskId) writes one nansen.run line per entity to
%   runs/<entityType>.runs.jsonl, in one write per entity type, so writers in
%   other sessions (or Python) can append at the same time. As Python's
%   nansen.runs.record; see that module for what the journal is for. mark
%   ("done" or "undone") records a step marked by hand instead.
    arguments
        folder (1,1) string
        methodId (1,1) string
        methodVersion (1,1) string
        entities (1,:) cell
        taskId (1,1) string = ""
        mark (1,1) string = ""
    end
    finished = char(datetime("now", Format="yyyy-MM-dd'T'HH:mm:ss"));
    entry = nansen.internal.schemaEntry("nansen.run");
    types = strings(1, 0);
    texts = strings(1, 0);
    for i = 1:numel(entities)
        line = struct("schemaType", 'nansen.run', "schemaVersion", char(entry.version), ...
            "method", struct("id", char(methodId), "version", char(methodVersion)), ...
            "key", entities{i}.Key, "finishedAt", finished);
        if taskId ~= ""
            line.task = char(taskId);
        end
        if mark ~= ""
            line.mark = char(mark);
        end
        if i == 1   % every line is built the same way
            nansen.checkDocument(line, ExpectedType="nansen.run");
        end
        type = string(entities{i}.EntityType);
        at = find(types == type, 1);
        if isempty(at)
            types(end + 1) = type; %#ok<AGROW>
            texts(end + 1) = ""; %#ok<AGROW>
            at = numel(types);
        end
        texts(at) = texts(at) + string(jsonencode(line)) + newline;
    end
    for i = 1:numel(types)
        runsFolder = fullfile(folder, "runs");
        if ~isfolder(runsFolder)
            mkdir(runsFolder);
        end
        fid = fopen(fullfile(runsFolder, types(i) + ".runs.jsonl"), "a", "n", "UTF-8");
        if fid < 0
            error("nansen:internal:recordRuns:CannotWrite", "Cannot append to the run journal of %s", types(i))
        end
        fwrite(fid, char(texts(i)), "char");   % one write: lines from other writers do not interleave with these
        fclose(fid);
    end
end
