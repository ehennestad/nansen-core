classdef DataTest < matlab.unittest.TestCase
%DataTest Data variables and file adapters on a real folder

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
            for path = ["sub-m1/ses-m1-001/movie.tif", "sub-m2/ses-m2-001/notes.txt"]
                target = fullfile(testCase.Folder, "data", "raw", path);
                mkdir(fileparts(target));
                nansen.internal.writeText(target, "frames");
            end
            mkdir(fullfile(testCase.Folder, "data", "processed", "m1", "m1-001"));
            project = nansen.Project.create(testCase.Folder, "Pilot", Dataset="dataset.dsm.json");
            project.addEntityType("subject");
            project.addEntityType("session");
            project.addDataVariable(DataTest.variable("movie", dataLocation="raw", filePattern="movie", fileAdapter="text"));
            project.addDataVariable(DataTest.variable("rois", dataLocation="processed", filePattern="roi_signals", ...
                fileName="{session_id}_roi.json", fileAdapter="json"));
            project.addDataVariable(DataTest.variable("summary", dataLocation="processed", subfolder="qc", ...
                fileName="summary.json", fileAdapter="json"));
            project.scan();
            testCase.Project = project;
        end
    end

    methods (Static)
        function doc = variable(name, fields)
            arguments
                name (1,1) string
                fields.dataLocation string = ""
                fields.filePattern string = ""
                fields.fileName string = ""
                fields.subfolder string = ""
                fields.fileAdapter string = ""
            end
            doc = struct("schemaType", 'nansen.dataVariable', "schemaVersion", '0.1.0', "name", char(name), ...
                "entityType", 'session');
            for field = ["dataLocation", "filePattern", "fileName", "subfolder", "fileAdapter"]
                if fields.(field) ~= ""
                    doc.(field) = char(fields.(field));
                end
            end
        end
    end

    methods
        function entity = session(testCase, sessionId)
            entity = testCase.Project.entity("session", struct("session_id", sessionId));
        end
    end

    methods (Test)
        function readThroughTheFilePattern(testCase)
            testCase.verifyEqual(testCase.session("m1-001").load("movie"), "frames");
            testCase.verifyError(@() testCase.session("m2-001").load("movie"), "nansen:DataNotFound");
        end

        function writeThenReadBackAfterAScan(testCase)
            path = testCase.session("m1-001").save("rois", struct("n", 3));
            testCase.verifyEqual(path, string(fullfile(testCase.Folder, "data", "processed", "m1", "m1-001", "m1-001_roi.json")));
            testCase.Project.scan();
            testCase.verifyEqual(testCase.session("m1-001").load("rois"), struct("n", 3));
        end

        function writeGeneratesTheEntityFolder(testCase)
            path = testCase.session("m2-001").save("rois", [1, 2]);
            testCase.verifyEqual(path, string(fullfile(testCase.Folder, "data", "processed", "m2", "m2-001", "m2-001_roi.json")));
        end

        function variableWithoutPatternUsesItsFileName(testCase)
            entity = testCase.session("m1-001");
            entity.save("summary", struct("ok", true));
            testCase.verifyEqual(entity.load("summary"), struct("ok", true));
            testCase.verifyEqual(testCase.Project.readTargets(entity, "summary"), ["processed", "m1/m1-001/qc/summary.json"]);
        end

        function dataStatus(testCase)
            entity = testCase.session("m1-001");
            entity.save("summary", struct());
            status = testCase.Project.dataStatus(entity);
            names = string(cellfun(@(s) s.name, status, UniformOutput=false));
            present = cellfun(@(s) ~isempty(s.files), status);
            testCase.verifyEqual(names, ["movie", "rois", "summary"]);
            testCase.verifyEqual(present, [true, false, true]);
        end

        function fileNameMustMatchThePattern(testCase)
            testCase.Project.addDataVariable(DataTest.variable("bad", dataLocation="processed", ...
                filePattern="roi_signals", fileName="{session_id}.json", fileAdapter="json"));
            testCase.verifyError(@() testCase.session("m1-001").save("bad", struct()), "nansen:FileNameMismatch");
        end

        function readingOnlyVariableCannotBeWritten(testCase)
            testCase.verifyError(@() testCase.session("m1-001").save("movie", "x"), "nansen:NoFileName");
        end

        function invalidVariablesAreRefused(testCase)
            project = testCase.Project;
            testCase.verifyError(@() project.addDataVariable(DataTest.variable("x", dataLocation="processed", ...
                fileName="x.json", fileAdapter="nope")), "nansen:UnknownFileAdapter");
            testCase.verifyError(@() project.addDataVariable(DataTest.variable("x", dataLocation="archive", ...
                fileName="x.json", fileAdapter="json")), "nansen:UnknownLocation");
            testCase.verifyError(@() project.addDataVariable(DataTest.variable("x", dataLocation="processed", ...
                filePattern="nope", fileAdapter="json")), "nansen:UnknownFilePattern");
            testCase.verifyError(@() project.addDataVariable(DataTest.variable("x", dataLocation="processed", ...
                fileAdapter="json")), "nansen:SchemaValidation");
        end

        function matAdapterRoundTrip(testCase)
            testCase.Project.addDataVariable(DataTest.variable("traces", dataLocation="processed", ...
                fileName="{session_id}_traces.mat", fileAdapter="mat"));
            entity = testCase.session("m1-001");
            entity.save("traces", struct("dff", [1, 2, 3]));
            testCase.verifyEqual(entity.load("traces").dff, [1, 2, 3]);
        end

        function npyReadsWhatNumpyWrites(testCase)
            % Fixtures written by numpy.save (C and Fortran order, big-endian, bool, 1-D, scalar), values in C order
            folder = fullfile(nansen.internal.repoRoot(), "testdata", "npy");
            expected = jsondecode(nansen.internal.readText(fullfile(folder, "expected.json")));
            adapter = testCase.Project.adapters().get("npy");
            for name = string(fieldnames(expected))'
                data = adapter.read(fullfile(folder, name + ".npy"));
                shape = reshape(expected.(name).shape, 1, []);
                if numel(shape) >= 2
                    testCase.verifyEqual(size(data), shape, name);
                    values = permute(data, numel(shape):-1:1);
                else
                    testCase.verifyEqual(numel(data), max([shape, 1]), name);
                    values = data;
                end
                testCase.verifyEqual(double(values(:)), double(expected.(name).values(:)), name);
            end
            testCase.verifyClass(adapter.read(fullfile(folder, "stack_uint16.npy")), "uint16");
            testCase.verifyClass(adapter.read(fullfile(folder, "mask_bool.npy")), "logical");
        end

        function npyRoundTrips(testCase)
            adapter = testCase.Project.adapters().get("npy");
            path = fullfile(testCase.Folder, "a.npy");
            for value = {uint16(reshape(0:23, 2, 3, 4)), single([1.5 2; -3 4]), int64([1; -2; 3]), true(2, 3), 7.25, zeros(0, 3)}
                adapter.write(path, value{1});
                back = adapter.read(path);
                testCase.verifyEqual(back, value{1});
            end
        end
        end

        function loadIsCachedUntilTheFileChanges(testCase)
            project = testCase.Project;
            entity = testCase.session("m1-001");
            entity.save("summary", struct("cells", [1, 2]));
            project.DataCache.removeAll();
            testCase.verifyEqual(project.load(entity, "summary"), struct("cells", [1; 2]));
            testCase.verifyEqual(project.load(entity, "summary"), struct("cells", [1; 2]));
            counts = project.DataCache.stats();
            testCase.verifyEqual(counts.hits, 1);
            paths = project.dataPaths(entity, "summary");
            nansen.internal.writeText(paths(1), '{"cells": [7, 8, 9]}');   % changed on disk, not through save
            testCase.verifyEqual(project.load(entity, "summary"), struct("cells", [7; 8; 9]));
            entity.save("summary", struct("cells", 5));   % save drops the entry, whatever the clock says
            testCase.verifyEqual(project.load(entity, "summary"), struct("cells", 5));
            testCase.verifyEqual(project.load(entity, "summary", Cached=false), struct("cells", 5));
        end

        function cacheKeepsWithinItsBudget(testCase)
            value = repmat('x', 1, 100);
            cache = nansen.DataCache(2 * nansen.DataCache.sizeOf(value));
            for key = ["a", "b", "c"]
                testCase.verifyEqual(cache.getOrLoad(key, 1, @() value), value);
            end
            counts = cache.stats();
            testCase.verifyEqual([counts.entries, counts.evictions], [2, 1]);
            cache.getOrLoad("huge", 1, @() repmat('y', 1, 1000));   % bigger than the budget: given, not kept
            counts = cache.stats();
            testCase.verifyEqual(counts.entries, 2);
        end
    end
end
