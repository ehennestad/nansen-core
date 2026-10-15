classdef MethodsTest < matlab.unittest.TestCase
%MethodsTest Modules, methods, options, presets and computed fragments

    properties
        Folder string
        Project
    end

    methods (TestMethodSetup)
        function makeProject(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            testCase.Folder = fixture.Folder;
            repo = fileparts(fileparts(fileparts(mfilename("fullpath"))));
            copyfile(fullfile(repo, "testdata", "entities-dataset.dsm.json"), fullfile(testCase.Folder, "dataset.dsm.json"));
            files = ["sub-m1/ses-m1-001/movie.tif", "sub-m1/ses-m1-001/.hidden", "sub-m1/ses-m1-002/movie.tif", ...
                "sub-m2/ses-m2-001/notes.txt"];
            sizes = [10, 5, 20, 1];
            for i = 1:numel(files)
                target = fullfile(testCase.Folder, "data", "raw", files(i));
                mkdir(fileparts(target));
                nansen.internal.writeText(target, repmat('x', 1, sizes(i)));
            end
            project = nansen.Project.create(testCase.Folder, "Pilot", Dataset="dataset.dsm.json");
            project.addModule("core");
            project.addEntityType("subject", Fragments="core.notes");
            project.addEntityType("session", Fragments=["core.notes", "core.file_stats"]);
            project.scan();
            project.sync("subject");
            project.sync("session");
            testCase.Project = project;
        end
    end

    methods (Test)
        function moduleFragmentsShapeTheTable(testCase)
            testCase.verifyEqual(testCase.Project.table("session").columnNames(), ...
                ["subject_id", "session_id", "ignore", "description", "n_files", "size_mb"]);
        end

        function methodsApplyToAnyEntityType(testCase)
            ids = sort([testCase.Project.entityMethods("session").Id]);
            testCase.verifyEqual(ids, ["core.backup", "core.export_keys", "core.file_stats", "core.wait"]);
            testCase.verifyEqual(testCase.Project.method("core.wait").Languages, ["matlab", "python"]);
        end

        function backupCopiesOnlyWhatChanged(testCase)
            project = testCase.Project;
            entities = project.entities("session");
            results = project.run("core.backup", entities(1:2), Options=struct("destination", "backup"));
            testCase.verifyEqual(cellfun(@(r) r.copied, results), [2, 1]);   % ses-m1-001 has a hidden file too
            copy = fullfile(project.Folder, "backup", "raw", "sub-m1", "ses-m1-001", "movie.tif");
            testCase.verifyEqual(strlength(string(nansen.internal.readText(copy))), 10);
            results = project.run("core.backup", entities(1:2), Options=struct("destination", "backup"));
            testCase.verifyEqual(cellfun(@(r) r.copied, results), [0, 0]);
            testCase.verifyEqual(cellfun(@(r) r.unchanged, results), [2, 1]);
            nansen.internal.writeText(fullfile(testCase.Folder, "data", "raw", "sub-m1", "ses-m1-001", "movie.tif"), repmat('y', 1, 12));
            results = project.run("core.backup", entities(1), Options=struct("destination", "backup"));
            testCase.verifyEqual(results{1}.copied, 1);
            testCase.verifyEqual(strlength(string(nansen.internal.readText(copy))), 12);
            results = project.run("core.backup", entities(1), Options=struct("destination", "backup", "overwrite", true));
            testCase.verifyEqual(results{1}.copied, 2);
            testCase.verifyError(@() project.run("core.backup", entities(1)), "nansen:InvalidOptions");   % no destination
        end

        function aMethodStartedFromTheTemplatesRuns(testCase)
            project = testCase.Project;
            method = project.createMethod("count_frames", Title="Count frames", EntityType="session", Description="Counts the frames.");
            testCase.verifyEqual(method.Languages, ["matlab", "python"]);
            code = string(nansen.internal.readText(fullfile(project.Folder, "matlab", "count_frames.m")));
            testCase.verifyTrue(startsWith(code, "function result = count_frames(entity, options, context)"));
            testCase.verifyTrue(isfile(fullfile(project.Folder, "python", "count_frames.py")));
            entities = project.entities("session");
            results = project.run("count_frames", entities(1));
            testCase.verifyEqual(results{1}, struct());
            testCase.verifyError(@() project.createMethod("count_frames"), "nansen:MethodExists");
            testCase.verifyError(@() project.createMethod("Count"), "nansen:InvalidParams");
            batch = project.createMethod("summarize", BatchMode="batch", Languages="matlab");
            testCase.verifyEqual(batch.Languages, "matlab");
            testCase.verifyTrue(contains(string(nansen.internal.readText(fullfile(project.Folder, "matlab", "summarize.m"))), ...
                "function result = summarize(entities, options, context)"));
        end

        function aProjectToolRunsOnceOnTheProject(testCase)
            project = testCase.Project;
            tool = project.createMethod("tally", Title="Tally", EntityType="@project");
            testCase.verifyTrue(tool.isTool());
            code = fullfile(project.Folder, "matlab", "tally.m");
            text = string(nansen.internal.readText(code));
            testCase.verifyTrue(startsWith(text, "function result = tally(project, options, context)"));
            nansen.internal.writeText(code, replace(text, "result = struct();", "result = struct(""sessions"", numel(project.entities(""session"")));"));
            rehash
            clear("tally")   % written in the same second as the template, which a timestamp check could miss
            testCase.verifyEqual([project.tools().Id], "tally");
            testCase.verifyFalse(ismember("tally", [project.entityMethods("session").Id]));
            testCase.verifyEqual(project.runTool("tally").sessions, 3);
            testCase.verifyError(@() project.runTool("core.wait"), "nansen:WrongEntityType");
        end

        function defaultOptionsAndValidation(testCase)
            method = testCase.Project.method("core.wait");
            defaults = method.defaultOptions();
            testCase.verifyEqual(defaults.seconds, 2);
            testCase.verifyEqual(defaults.steps, 10);
            testCase.verifyEqual(method.resolveOptions(struct("seconds", 0)).steps, 10);
            testCase.verifyError(@() method.resolveOptions(struct("seconds", -1)), "nansen:InvalidOptions");
        end

        function presets(testCase)
            project = testCase.Project;
            project.savePreset("core.wait", "quick", struct("seconds", 0, "steps", 1), "No waiting");
            names = string(cellfun(@(p) p.name, project.presets("core.wait"), UniformOutput=false));
            testCase.verifyEqual(names, ["default", "quick"]);
            testCase.verifyEqual(project.preset("core.wait", "quick").seconds, 0);
            testCase.verifyError(@() project.savePreset("core.wait", "default", struct()), "nansen:InvalidOptions");
            testCase.verifyError(@() project.savePreset("core.wait", "broken", struct("steps", 0)), "nansen:InvalidOptions");
            project.deletePreset("core.wait", "quick");
            testCase.verifyEqual(numel(project.presets("core.wait")), 1);
        end

        function runSerialWithProgressAndLog(testCase)
            context = nansen.MethodContext();
            results = testCase.Project.run("core.wait", testCase.Project.entities("session"), ...
                Options=struct("seconds", 0, "steps", 2), Context=context);
            testCase.verifyEqual(cellfun(@(r) r.waited, results), [0, 0, 0]);
            testCase.verifyEqual(context.Fraction, 1);
            testCase.verifyEqual(numel(context.Lines), 3);
        end

        function runBatch(testCase)
            sessions = testCase.Project.entities("session");
            results = testCase.Project.run("core.export_keys", sessions(1:2), Options=struct("fileName", "two.csv"));
            text = string(fileread(results{1}.path));
            testCase.verifyEqual(text, "subject_id,session_id" + newline + "m1,m1-001" + newline + "m1,m1-002" + newline);
        end

        function cancelStopsBeforeTheNextEntity(testCase)
            context = nansen.MethodContext();
            context.cancel();
            testCase.verifyError(@() testCase.Project.run("core.wait", testCase.Project.entities("session"), ...
                Options=struct("seconds", 0, "steps", 1), Context=context), "nansen:Cancelled");
        end

        function updateComputedFragment(testCase)
            summary = testCase.Project.updateFragment("session", "core.file_stats");
            testCase.verifyEqual(summary.updated, 3);
            testCase.verifyEmpty(summary.failed);
            table = testCase.Project.table("session");
            testCase.verifyEqual(table.Data.n_files, [1; 1; 1]);
            testCase.verifyEqual(table.Data.size_mb, [1e-05; 2e-05; 1e-06]);
        end

        function updateOnlySomeKeys(testCase)
            testCase.Project.updateFragment("session", "core.file_stats", ...
                Keys={struct("subject_id", "m1", "session_id", "m1-002")});
            table = testCase.Project.table("session");
            testCase.verifyEqual(table.Data.session_id(~isnan(table.Data.n_files)), "m1-002");
        end

        function fragmentsWithoutComputeCannotBeUpdated(testCase)
            testCase.verifyError(@() testCase.Project.updateFragment("session", "core.notes"), "nansen:NotComputed");
        end

        function unknownModule(testCase)
            testCase.verifyError(@() testCase.Project.addModule("nope"), "nansen:UnknownModule");
        end

        function columnsAreImportedFromDevTableVariables(testCase)   % dev's Import Table Variable
            project = testCase.Project;
            dev = fullfile(nansen.internal.repoRoot(), "conformance", "api", "column-import", "data", "dev");
            [fragment, method, files] = project.importColumn("session", fullfile(dev, "numFrames.m"));
            testCase.verifyEqual(string(files), ["fragments/num_frames.fragment.nansen.json", "methods/num_frames.method.nansen.json", ...
                "matlab/num_frames.m", "matlab/num_frames_value.m"]);
            testCase.verifyEqual(method.Languages, "matlab");
            testCase.verifyEqual(string(fragment.Document.compute.method), "num_frames");
            testCase.verifyEqual([fragment.Columns.Name], "numFrames");
            copied = string(nansen.internal.readText(fullfile(project.Folder, "matlab", "num_frames_value.m")));
            testCase.verifyEqual(copied, replace(string(nansen.internal.readText(fullfile(dev, "numFrames.m"))), ...
                "function value = numFrames(", "function value = num_frames_value("));
            % dev's function, given the entity, computes the column: the length of the session id
            summary = project.updateFragment("session", "num_frames");
            testCase.verifyEqual(summary.updated, 3);
            testCase.verifyEqual(project.table("session").Data.numFrames, [6; 6; 6]);
            [fragment, method] = project.importColumn("session", fullfile(dev, "Quality.m"), Title="Recording quality");
            testCase.verifyTrue(isnumeric(method) && isnan(method));   % typed in: no method
            testCase.verifyFalse(isfield(fragment.Document, "compute"));
            column = nansen.internal.asCellOfStructs(fragment.Document.columns);
            testCase.verifyEqual(string(column{1}.choices)', ["good", "fair", "poor"]);
            testCase.verifyEqual(string(column{1}.title), "Recording quality");
            fragment = project.importColumn("subject", fullfile(dev, "Reviewed.m"));
            column = nansen.internal.asCellOfStructs(fragment.Document.columns);
            testCase.verifyEqual([string(column{1}.dataType), string(column{1}.default)], ["boolean", "false"]);
            testCase.verifyError(@() project.importColumn("session", fullfile(dev, "numFrames.m")), "nansen:ColumnExists");
            % a method of the rebuild, under another id: its function is named as its file
            rebuild = fullfile(fileparts(dev), "rebuild");
            [~, method, files] = project.importColumn("session", fullfile(rebuild, "stack_size.m"), Id="size_of_stack", ...
                Columns={struct("name", "height", "dataType", "integer"), struct("name", "width", "dataType", "integer")});
            testCase.verifyEqual(string(files{end}), "matlab/size_of_stack.m");
            testCase.verifyEqual(method.Id, "size_of_stack");
            testCase.verifyTrue(startsWith(string(nansen.internal.readText(fullfile(project.Folder, "matlab", "size_of_stack.m"))), ...
                "function result = size_of_stack(entity, options, context)"));
            project.updateFragment("session", "size_of_stack");
            testCase.verifyEqual(project.table("session").Data.width, [6; 6; 6]);
            testCase.verifyError(@() project.importColumn("session", fullfile(rebuild, "script.m")), "nansen:InvalidParams");
            testCase.verifyError(@() project.importColumn("session", fullfile(rebuild, "notes.txt")), "nansen:InvalidParams");
            testCase.verifyError(@() project.importColumn("session", fullfile(rebuild, "missing.m")), "nansen:FileNotFound");
        end

        function adaptersAreImportedWithTheirCode(testCase)   % dev's Import File Adapter
            project = testCase.Project;
            data = fullfile(nansen.internal.repoRoot(), "conformance", "api", "adapter-import", "data");
            result = project.importAdapter(fullfile(data, "single", "thing.fileAdapter.nansen.json"));
            testCase.verifyEqual(string(result.adapters{1}.files), ["file-adapters/thing.fileAdapter.nansen.json", ...
                "python/thing_reader.py", "matlab/ThingReader.m"]);
            file = fullfile(testCase.Folder, "a.thing");
            nansen.internal.writeText(file, 'one two three');
            testCase.verifyEqual(project.adapters().get("thing").read(file), {'one', 'two', 'three'});
            result = project.importAdapter(fullfile(data, "bundle"));
            testCase.verifyEqual(string(cellfun(@(a) a.id, result.adapters, UniformOutput=false)), ["three", "lab_two"]);
            testCase.verifyEqual(string(result.adapters{2}.files), ["file-adapters/lab_two.fileAdapter.nansen.json", ...
                "python/lab/two.py", "matlab/+lab/TwoAdapter.m"]);
            rows = fullfile(testCase.Folder, "rows.txt");
            nansen.internal.writeText(rows, sprintf('1 2 3\n4 5 6\n'));
            testCase.verifyEqual(project.adapters().get("lab_two").read(rows), {{'1', '2'}; {'4', '5'}});
            testCase.verifyError(@() project.importAdapter(fullfile(data, "single")), "nansen:AdapterExists");
            testCase.verifyError(@() project.importAdapter(fullfile(data, "broken", "nocode.fileAdapter.nansen.json")), "nansen:FileNotFound");
            testCase.verifyError(@() project.importAdapter(fullfile(data, "broken", "halfway.fileAdapter.nansen.json")), "nansen:InvalidParams");
            testCase.verifyFalse(isfile(fullfile(project.Folder, "matlab", "HalfwayAdapter.m")));   % nothing copied
        end
    end
end
