function result = nansenCoreExportKeys(entities, options, context)
%nansenCoreExportKeys Write the selected entities' keys to exports/<fileName> in the project folder
    folder = fullfile(context.Project.Folder, "exports");
    if ~isfolder(folder)
        mkdir(folder);
    end
    path = string(fullfile(folder, options.fileName));
    names = string(fieldnames(entities{1}.Key))';
    lines = join(names, ",");
    for i = 1:numel(entities)
        values = arrayfun(@(n) nansen.internal.formatToken(entities{i}.Key.(n)), names);
        lines(end + 1) = join(values, ","); %#ok<AGROW>
    end
    nansen.internal.writeText(path, join(lines, newline) + newline);
    context.log("wrote %d keys to %s", numel(entities), path);
    result = struct("path", path, "count", numel(entities));
end
