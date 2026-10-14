function project = create(folder, options)
%create Write a demo dataset and project into an empty folder, scan it and fill the tables
%
%   project = nansen.demo.create(folder) builds what the core module's
%   demo/ folder describes (demo.json, dataset.dsm.json): a small two-photon
%   dataset on disk, raw and partly processed, and a project over it with
%   notes, file statistics and a method preset. Python's `nansen demo`
%   builds the same from the same files.
%
%   Open it in the app with nansen.App(Project=project.Folder).
%
%   create(folder, Seed=n) draws the random parts (file sizes, start
%   minutes, missing config files, notes) from a local random stream.
    arguments
        folder (1,1) string
        options.Seed (1,1) double = 7
    end
    if isfolder(folder) && numel(dir(folder)) > 2
        nansen.internal.throwError("folder-not-empty", "%s is not empty", folder)
    end
    demoFolder = fullfile(nansen.Module.builtInFolder(), "core", "demo");
    plan = nansen.internal.readJson(fullfile(demoFolder, "demo.json"));
    stream = RandStream("twister", Seed=options.Seed);
    if ~isfolder(folder)
        mkdir(folder);
    end
    copyfile(fullfile(demoFolder, "dataset.dsm.json"), fullfile(folder, "dataset.dsm.json"));
    for subject = reshape(string(fieldnames(plan.subjects)), 1, [])
        sessions = string(plan.subjects.(subject));
        for number = 0:numel(sessions) - 1
            session = sessions(number + 1);
            date = extractBefore(session, 9);
            day = extractBefore(date, 5) + "_" + extractBetween(date, 5, 6) + "_" + extractAfter(date, 6);
            hour = 9 + number * 2;
            name = sprintf("%s_%02d_%02d_00_%s-%s", day, hour, randi(stream, [0, 59]), subject, session);
            raw = fullfile(folder, "data", "raw", day, name);
            mkdir(raw);
            writeBytes(fullfile(raw, "rec.raw"), randi(stream, [2000, 20000]));
            if rand(stream) < plan.configChance
                nansen.internal.writeText(fullfile(raw, "rec.ini"), "[scan]" + newline + "zoom=2" + newline);
            end
            if number < numel(sessions) - 1   % the newest session of each subject is not processed yet
                processed = fullfile(folder, "data", "processed", "subject-" + subject, "session-" + subject + "-" + session);
                mkdir(processed);
                nansen.internal.writeText(fullfile(processed, subject + "-" + session + "_motion_corrected.json"), ...
                    jsonencode(struct("shifts", rand(stream, 1, 5))));
            end
        end
    end
    info = plan.project;
    project = nansen.Project.create(folder, info.name, Title=info.title, Dataset="dataset.dsm.json", ...
        Description=info.description);
    project.addModule("core");
    entityTypes = nansen.internal.asCellOfStructs(plan.entityTypes);
    for i = 1:numel(entityTypes)
        project.addEntityType(entityTypes{i}.name, [], Fragments=reshape(string(entityTypes{i}.fragments), 1, []), ...
            Title=entityTypes{i}.title);
    end
    for document = nansen.internal.asCellOfStructs(plan.dataVariables)
        project.addDataVariable(document{1});
    end
    project.scan();
    for i = 1:numel(entityTypes)
        project.sync(entityTypes{i}.name);
    end
    sessions = project.table("session");
    notes = string(plan.notes);
    for row = sessions.toJsonRows()
        key = struct("subject_id", row{1}.subject_id, "session_id", row{1}.session_id);
        note = notes(randi(stream, numel(notes)));
        values = struct("description", [], "ignore", rand(stream) < plan.ignoreChance);
        if note ~= ""
            values.description = note;
        end
        sessions.updateRow(key, values);
    end
    sessions.write();
    project.updateFragment("session", "core.file_stats");
    for preset = nansen.internal.asCellOfStructs(plan.presets)
        project.savePreset(preset{1}.methodId, preset{1}.name, preset{1}.values, preset{1}.description);
    end
    project = nansen.Project.open(folder);
end

function writeBytes(path, count)
    file = fopen(path, "w");
    closer = onCleanup(@() fclose(file));
    fwrite(file, zeros(1, count, "uint8"));
end
