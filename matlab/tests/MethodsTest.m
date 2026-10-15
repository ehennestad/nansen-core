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
    end
end
