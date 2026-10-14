function result = nansenCoreFileStats(entity, options, context)
%nansenCoreFileStats Count the files in the entity's folders in every data location, and their total size in MB
    dataset = context.Project.dataset();
    count = 0;
    total = 0;
    for location = entity.locations()
        entry = location{1};
        root = dataset.root(string(entry.dataLocationIdentifier), string(entry.rootStoragePathIdentifier)).Path;
        for relative = reshape(string(nansen.internal.asCellstr(entry.paths)), 1, [])
            target = fullfile(root, relative);
            if isfile(target)
                files = dir(target);
            elseif isfolder(target)
                files = dir(fullfile(target, "**", "*"));
                files = files(~[files.isdir]);
            else
                files = [];
            end
            for i = 1:numel(files)
                inside = erase(string(fullfile(files(i).folder, files(i).name)), string(root));
                parts = split(strip(replace(inside, "\", "/"), "left", "/"), "/");
                if ~options.includeHidden && any(startsWith(parts, "."))
                    continue
                end
                count = count + 1;
                total = total + files(i).bytes;
            end
        end
    end
    context.log("%s: %d files", strjoin(string(struct2cell(entity.Key)), " / "), count);
    result = struct("n_files", count, "size_mb", round(total / 1e6, 6));
end
