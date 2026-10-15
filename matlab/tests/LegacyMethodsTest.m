classdef LegacyMethodsTest < matlab.unittest.TestCase
%LegacyMethodsTest NANSEN dev's session methods, imported as they are and run through nansen.legacy.SessionShim

    properties
        Folder string
        Project
        Dev string   % a folder of dev session methods, as a dev project keeps them (code/+<name>/+sessionmethod)
    end

    methods (TestMethodSetup)
        function makeProject(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            testCase.Folder = fixture.Folder;
            repo = fileparts(fileparts(fileparts(mfilename("fullpath"))));
            copyfile(fullfile(repo, "testdata", "entities-dataset.dsm.json"), fullfile(testCase.Folder, "dataset.dsm.json"));
            for file = ["sub-m1/ses-m1-001/movie.tif", "sub-m1/ses-m1-002/movie.tif", "sub-m1/ses-m1-002/second.tif", ...
                    "sub-m2/ses-m2-001/notes.txt"]
                target = fullfile(testCase.Folder, "data", "raw", file);
                mkdir(fileparts(target));
                nansen.internal.writeText(target, 'x');
            end
            project = nansen.Project.create(testCase.Folder, "Pilot", Dataset="dataset.dsm.json");
            project.addModule("core");
            project.addEntityType("subject", Fragments="core.notes");
            project.addEntityType("session", Fragments="core.notes");
            project.scan();
            project.sync("subject");
            project.sync("session");
            testCase.Project = project;
            % the conformance case's dev methods (a function of dev's template, a class), and one more, in a temporary folder
            testCase.Dev = fullfile(testCase.Folder, "dev", "+lab", "+sessionmethod");
            mkdir(testCase.Dev);
            copyfile(fullfile(repo, "conformance", "api", "legacy-methods", "data", "+lab", "+sessionmethod"), testCase.Dev);
            LegacyMethodsTest.writeShimMethod(fullfile(testCase.Dev, "+data"));
        end
    end

    methods (Static)
        function writeShimMethod(folder)
            % A function session method that uses the parts of dev's session object that methods use
            mkdir(folder);
            lines = [
                "function varargout = checkShim(sessionObject, varargin)"
                "%CHECKSHIM Use the parts of dev's session object that methods use."
                "    params = getDefaultParameters();"
                "    ATTRIBUTES = {'serial'};"
                "    fcnAttributes = nansen.session.SessionMethod.setAttributes(params, ATTRIBUTES{:});"
                "    if ~nargin && nargout > 0"
                "        varargout = {fcnAttributes};   return"
                "    end"
                "    params = utility.parsenvpairs(params, [], varargin);"
                "    S = struct();"
                "    S.sessionID = sessionObject.sessionID;"
                "    S.subjectID = sessionObject.subjectID;"
                "    S.number = sessionObject.session_number;"
                "    S.raw = sessionObject.getSessionFolder('Raw');"
                "    S.hadProcessed = sessionObject.existSessionFolder('processed');"
                "    S.processed = sessionObject.getSessionFolder('processed', 'create');"
                "    S.path = sessionObject.getDataFilePath('ShimNotes', '-w', 'Subfolder', 'notes', 'FileType', '.json');"
                "    S.tags = params.Tags;"
                "    S.limit = params.Limit;"
                "    S.computed = params.Computed;"
                "    sessionObject.saveData('ShimNotes', S)"
                "    notes = sessionObject.loadData('ShimNotes');"
                "    sessionObject.saveData('ShimEcho', notes.sessionID)"
                "    S.echo = sessionObject.loadData('ShimEcho');"
                "    sessionObject.saveData('ShimNotes', S)"
                "end"
                ""
                "function params = getDefaultParameters()"
                "    params = struct();"
                "    params.Tags = {'a', 'b'};"
                "    params.Limit = 3; % At most this many"
                "    params.Computed = upper('dev');"
                "end"
                ];
            nansen.internal.writeText(fullfile(folder, "checkShim.m"), strjoin(lines', newline) + newline);
        end
    end

    methods (Test)
        function aFunctionMethodRunsWithTheShim(testCase)
            project = testCase.Project;
            result = project.importLegacyMethods(fullfile(testCase.Dev, "+data", "checkShim.m"));
            testCase.verifyEqual(string(result.methods{1}.id), "legacy.check_shim");
            testCase.verifyTrue(result.methods{1}.legacy);
            testCase.verifyTrue(isfile(fullfile(testCase.Folder, "matlab", "+lab", "+sessionmethod", "+data", "checkShim.m")));
            method = project.method("legacy.check_shim");
            testCase.verifyEqual(method.Languages, "matlab");
            testCase.verifyEqual(fieldnames(method.optionsSchema().properties), {'Tags'; 'Limit'});   % Computed is dev's at run time

            entity = project.entity("session", struct("subject_id", "m1", "session_id", "m1-001"));
            results = project.run("legacy.check_shim", {entity}, Options=struct("Limit", 5));
            testCase.verifyEqual(results{1}, struct());
            notes = project.load(entity, "ShimNotes");
            testCase.verifyEqual(string(notes.sessionID), "m1-001");
            testCase.verifyEqual(string(notes.subjectID), "m1");
            testCase.verifyEqual(notes.number, 1);   % a DSM attribute, as a property of its name
            testCase.verifyTrue(endsWith(replace(string(notes.raw), "\", "/"), "data/raw/sub-m1/ses-m1-001"));
            testCase.verifyFalse(notes.hadProcessed);
            testCase.verifyTrue(isfolder(notes.processed));
            testCase.verifyTrue(endsWith(replace(string(notes.path), "\", "/"), "m1/m1-001/notes/m1-001_shim_notes.json"));
            testCase.verifyEqual(string(notes.tags), ["a"; "b"]);
            testCase.verifyEqual(notes.limit, 5);
            testCase.verifyEqual(string(notes.computed), "DEV");
            testCase.verifyEqual(string(notes.echo), "m1-001");
            variable = project.dataVariable("ShimEcho");   % made as dev's createVariable made one
            testCase.verifyEqual([variable.DataLocation, variable.FileName, variable.FileAdapter, variable.VariableInFile], ...
                ["processed", "{session_id}_shim_echo.mat", "mat", "ShimEcho"]);
            testCase.verifyEqual(project.dataVariable("ShimNotes").Subfolder, "notes");
        end

        function aFunctionMethodGetsDevsOptionsInDevsShapes(testCase)
            project = testCase.Project;
            project.importLegacyMethods(fullfile(testCase.Dev, "+process", "countFiles.m"));
            method = project.method("legacy.count_files");
            defaults = method.defaultOptions();
            testCase.verifyEqual(string(defaults.Extension), ".tif");
            testCase.verifyFalse(defaults.Advanced.Verbose);
            entity = project.entity("session", struct("subject_id", "m1", "session_id", "m1-002"));
            testCase.verifyError(@() project.run("legacy.count_files", {entity}, Options=struct("Extension", ".png")), ...
                "nansen:InvalidOptions");   % not among dev's choices
            project.run("legacy.count_files", {entity}, Options=struct("Scale", 10));
            count = project.load(entity, "FileCount");
            testCase.verifyEqual(count.count, 20);   % two .tif files
            testCase.verifyEqual(count.window, [1, 10]);
            testCase.verifyEqual(count.label, 'it''s 100% files');
            testCase.verifyFalse(count.verbose);
            testCase.verifyEqual(project.dataVariable("FileCount").FileName, "{session_id}_file_count.mat");
        end

        function aClassMethodRunsOnAllSessionsAtOnce(testCase)
            project = testCase.Project;
            result = project.importLegacyMethods(fullfile(testCase.Dev, "+plot"));
            testCase.verifyEmpty(result.warnings);
            method = project.method("legacy.summarize_sessions");
            testCase.verifyEqual(method.BatchMode, "batch");
            testCase.verifyFalse(method.Queueable);
            testCase.verifyEqual(string(method.Document.legacySessionMethod.kind), "class");
            entities = project.entities("session");
            results = project.run("legacy.summarize_sessions", entities(1:2), Options=struct("Repeat", 1, "Prefix", "Run"));
            testCase.verifyEqual(results, {struct()});
            for i = 1:2
                text = project.load(entities{i}, "SessionSummary");
                testCase.verifyEqual(string(text), "Run " + string(entities{i}.Key.session_id) + " of " + ...
                    string(entities{i}.Key.subject_id));
            end
            testCase.verifyEqual(project.dataVariable("SessionSummary").FileAdapter, "text");
        end

        function aFolderImportsEachSessionMethodInIt(testCase)
            project = testCase.Project;
            result = project.importLegacyMethods(fullfile(testCase.Folder, "dev", "+lab"));
            ids = string(cellfun(@(m) m.id, result.methods, UniformOutput=false));
            testCase.verifyEqual(ids, ["legacy.check_shim", "legacy.summarize_sessions", "legacy.count_files"]);
            testCase.verifyEqual(string(result.methods{2}.category), "Plot");
            testCase.verifyEqual(string(result.warnings), "session method +sessionmethod/helper.m: helper.m does not call " + ...
                "nansen.session.SessionMethod.setAttributes, so it is not a dev session method; left out");
            testCase.verifyError(@() project.importLegacyMethods(fullfile(testCase.Dev, "+process")), "nansen:MethodExists");
            testCase.verifyError(@() project.importLegacyMethods(fullfile(testCase.Dev, "helper.m")), "nansen:UnsupportedFile");
            testCase.verifyError(@() project.importLegacyMethods(fullfile(testCase.Dev, "missing.m")), "nansen:FileNotFound");
            testCase.verifyError(@() project.importLegacyMethods(testCase.Dev, EntityType="probe"), "nansen:UnknownEntityType");
        end

        function theShimFindsVariablesAndFoldersByDevsNames(testCase)
            project = testCase.Project;
            entity = project.entity("session", struct("subject_id", "m1", "session_id", "m1-001"));
            context = nansen.MethodContext(Project=project);
            session = nansen.legacy.SessionShim(entity, context);
            testCase.verifyEqual(session.sessionID, 'm1-001');
            testCase.verifyEqual(session.getDataId(), 'm1-001');
            testCase.verifyError(@() session.loadData("Missing"), "NANSEN:Session:VariableNotFound");
            testCase.verifyError(@() session.validateVariable({'Missing'}), "NANSEN:Session:RequiredDataMissing");
            testCase.verifyError(@() session.getSessionFolder("processed"), "NANSEN:Session:FolderNotFound");
            testCase.verifyError(@() session.getSessionFolder("nowhere"), "nansen:UnknownLocation");
            session.saveData("roi_count", 12);
            testCase.verifyEqual(session.loadData("RoiCount"), 12);   % of any case, without underscores
            testCase.verifyTrue(session.existVariable("ROI_COUNT"));
            [path, info] = session.getDataFilePath("roi_count");
            testCase.verifyTrue(isfile(path));
            testCase.verifyEqual(info.FileAdapter, 'mat');
            testCase.verifyTrue(session.existSessionFolder("Processed"));
            testCase.verifyEqual(string(session.getSessionFolder()), string(session.getSessionFolder("raw")));
        end

        function theAnalysisMatchesPython(testCase)
            % The same file as python/tests/test_legacymethods.py, read the same way
            lines = [
                "function varargout = measure(sessionObject, varargin)"
                "%MEASURE Measure something."
                "    params = getDefaultParameters();"
                "    params.Inline = 'set here'; % set in the function itself"
                "    ATTRIBUTES = {'batch', 'unqueueable', 'MethodName', 'Measure it'};"
                "    S = nansen.session.SessionMethod.setAttributes(params, ATTRIBUTES{:});"
                "    params.After = 1;   % after setAttributes: not a default"
                "end"
                ""
                "function P = getDefaultParameters()"
                "    P = struct();"
                "    P.Threshold = -1.5e-2;      % how low; it's 100% ""sure"""
                "    P.Count = +3"
                "    P.Name = 'it''s';"
                "    P.Quoted = ""say """"hi"""""";"
                "    P.Row = [1 2.5, 3];"
                "    P.One = [7];"
                "    P.Empty = [];"
                "    P.Names = {'a' , ""b""};"
                "    P.NoNames = {};"
                "    P.Flag = true;"
                "    P.Mode = 'fast';"
                "    P.Mode_ = {'fast', 'slow'};"
                "    P.Other = 'x';"
                "    P.Other_ = {'y', 'z'};"
                "    P.Sub.Deep.Value = 2;"
                "    P.Sub.Gone = 1;"
                "    P.Sub.Gone = getenv('HOME');"
                "    P.Computed = numel(x');"
                "    P.Transposed = x'; % 'not a string"
                "    P.Matrix = [1, 2; 3, 4];"
                "end"
                ];
            info = nansen.legacy.analyzeSessionMethod("measure", strjoin(lines', newline));
            testCase.verifyEqual([info.kind, info.title, info.description, info.batchMode], ...
                ["function", "Measure it", "Measure something.", "batch"]);
            testCase.verifyFalse(info.queueable);
            properties = info.options.properties;
            testCase.verifyEqual(string(fieldnames(properties))', ["Threshold", "Count", "Name", "Quoted", "Row", "One", ...
                "Names", "NoNames", "Flag", "Mode", "Other", "Sub", "Inline"]);
            testCase.verifyEqual(properties.Threshold.default, -1.5e-2);
            testCase.verifyEqual(string(properties.Threshold.description), "how low; it's 100% ""sure""");
            testCase.verifyEqual(properties.Count.default, 3);
            testCase.verifyEqual(properties.Name.default, 'it''s');
            testCase.verifyEqual(properties.Quoted.default, 'say "hi"');
            testCase.verifyEqual(properties.Row.default, [1, 2.5, 3]);
            testCase.verifyEqual(string(properties.Row.type), "array");
            testCase.verifyEqual(properties.One.default, 7);
            testCase.verifyEqual(properties.Names.default, {'a', 'b'});
            testCase.verifyEqual(string(properties.NoNames.type), "array");
            testCase.verifyTrue(properties.Flag.default);
            testCase.verifyEqual(properties.Mode.enum, {'fast', 'slow'});
            testCase.verifyFalse(isfield(properties.Other, "enum"));
            testCase.verifyEqual(fieldnames(properties.Sub.properties), {'Deep'});
            testCase.verifyEqual(properties.Sub.properties.Deep.properties.Value.default, 2);
            testCase.verifyEqual(string(properties.Inline.description), "set in the function itself");
            for bad = ["% only a comment", "x = 1;", "function y = f(x)" + newline + "y = x;", "classdef f < handle", ...
                    "classdef f < nansen.processing.MotionCorrection & nansen.session.SessionMethod"]
                testCase.verifyError(@() nansen.legacy.analyzeSessionMethod("f", bad), "nansen:UnsupportedFile", bad);
            end
        end
    end
end
