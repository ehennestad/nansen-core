function result = nansenCoreBackup(entity, options, context)
%nansenCoreBackup Copy the entity's folders to <destination>/<data location>/<the same path>, leaving up-to-date copies alone
    dataset = context.Project.dataset();
    destination = string(options.destination);
    if ~startsWith(destination, ["/", "\"]) && isempty(regexp(destination, "^[A-Za-z]:", "once"))
        destination = fullfile(context.Project.Folder, destination);
    end
    destination = nansen.internal.normalizePath(destination);
    copied = 0;
    unchanged = 0;
    total = 0;
    for location = entity.locations()
        entry = location{1};
        locationId = string(entry.dataLocationIdentifier);
        if string(options.dataLocation) ~= "" && locationId ~= string(options.dataLocation)
            continue
        end
        root = nansen.internal.normalizePath(dataset.root(locationId, string(entry.rootStoragePathIdentifier)).Path);
        for relative = reshape(string(nansen.internal.asCellstr(entry.paths)), 1, [])
            source = nansen.internal.normalizePath(root + "/" + relative);
            if destination == source || startsWith(destination, regexprep(source, "/$", "") + "/")
                error("nansen:core:BackupInside", "the destination %s is inside %s", destination, source)
            end
            if isfile(source)
                files = dir(source);
            elseif isfolder(source)
                files = dir(fullfile(source, "**", "*"));
                files = files(~[files.isdir]);
            else
                files = [];
            end
            if ~isempty(files)
                [~, order] = sort(string(fullfile({files.folder}, {files.name})));
                files = files(order);
            end
            for i = 1:numel(files)
                file = nansen.internal.normalizePath(fullfile(files(i).folder, files(i).name));
                inside = extractAfter(file, strlength(regexprep(root, "/$", "")) + 1);
                target = destination + "/" + locationId + "/" + inside;
                if ~options.overwrite && isfile(target)
                    copy = dir(target);
                    if copy.bytes == files(i).bytes && copy.datenum + 1 / 86400 >= files(i).datenum
                        unchanged = unchanged + 1;
                        continue
                    end
                end
                context.checkCancelled();
                folder = fileparts(target);
                if ~isfolder(folder)
                    mkdir(folder);
                end
                copyfile(file, target, "f");
                copied = copied + 1;
                total = total + files(i).bytes;
            end
        end
    end
    context.log("%s: %d copied, %d up to date", strjoin(string(struct2cell(entity.Key)), " / "), copied, unchanged);
    result = struct("copied", copied, "unchanged", unchanged, "size_mb", round(total / 1e6, 6));
end
