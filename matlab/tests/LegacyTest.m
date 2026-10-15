classdef LegacyTest < matlab.unittest.TestCase
%LegacyTest Importing a NANSEN dev project: reading its .mat files, and the project made from them

    properties
        Folder string
        Legacy string
    end

    methods (TestMethodSetup)
        function makeLegacyProject(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            testCase.Folder = fixture.Folder;
            testCase.Legacy = fullfile(testCase.Folder, "RatNav");
            LegacyTest.writeLegacyProject(testCase.Legacy, fullfile(testCase.Folder, "raw"));
            mkdir(fullfile(testCase.Folder, "processed"));
            for path = ["m110/2025_05_23/session-m110-001", "m110/2025_05_24/session-m110-002", ...
                    "m111/2025_05_25/session-m111-001", "m112_old/2025_05_26/session-m112-001"]
                target = fullfile(testCase.Folder, "raw", path);
                mkdir(target);
                session = extractAfter(path, "session-");
                nansen.internal.writeText(fullfile(target, session + "_config.json"), '{"zoom": 2}');
            end
        end
    end

    methods (Static)
        function writeLegacyProject(folder, rawRoot)
            % The files of a dev project, as dev writes them (see NANSEN dev: Project, MetaTable, StorableCatalog)
            mkdir(fullfile(folder, "configurations"));
            mkdir(fullfile(folder, "metadata", "tables"));
            nansen.internal.writeJson(fullfile(folder, "project.nansen.json"), struct( ...
                "x_type", 'NANSEN Project Specification', "x_version", '1.0.0', ...
                "Properties", struct("Name", 'Rat Navigation', "ShortName", 'RatNav', "Description", 'Imported from dev'), ...
                "Preferences", struct()));

            metadata = struct("VariableName", {'Subject ID', 'Session ID', 'Experiment Date', 'Experiment Time'}, ...
                "SubfolderLevel", {1, 3, 2, []}, "StringDetectMode", {'ind', 'expr', 'ind', 'ind'}, ...
                "StringDetectInput", {'1:end', 'm\d{3}-\d{3}', '1:10', '1:end'}, ...
                "StringFormat", {'', '', 'yyyy_MM_dd', ''}, "Separator", {'', '', '', ''}, ...
                "FunctionName", {'', '', '', ''});
            raw = struct("Name", 'Rawdata', "Type", 'recorded', "Uuid", 'a1', ...
                "RootPath", struct("Key", 'local', "Value", char(rawRoot), "DiskName", 'LabDisk'), ...
                "ExamplePath", '', "DataSubfolders", {{}}, ...
                "SubfolderStructure", struct("Name", {'m110', '2025_05_23', 'session-m110-001'}, ...
                    "Type", {'Subject', 'Date', 'Session'}, "Expression", {'^m\d{3}$', '', 'session'}, ...
                    "IgnoreList", {{'old'}, {}, {}}, "IsFolder", {true, true, true}), ...
                "MetaDataDef", metadata);
            processed = raw;
            processed.Name = 'Processed';
            processed.Type = 'processed';
            processed.RootPath = struct("Key", 'x1', "Value", char(fullfile(fileparts(rawRoot), "processed")), "DiskName", '');
            processed.SubfolderStructure = struct("Name", {'', ''}, "Type", {'Subject', 'Session'}, ...
                "Expression", {'', ''}, "IgnoreList", {{}, {}}, "IsFolder", {true, true});
            processed.MetaDataDef = metadata(1:2);
            processed.MetaDataDef(2).SubfolderLevel = 2;
            processed.MetaDataDef(2).StringDetectInput = '1:end';
            processed.MetaDataDef(2).StringDetectMode = 'ind';
            Data = [raw, processed];
            Preferences = struct("DefaultDataLocation", 'Rawdata');
            save(fullfile(folder, "configurations", "datalocation_settings.mat"), "Data", "Preferences");

            Data = struct("VariableName", {'SessionConfig', 'RoiArray', 'MotionCorrected', 'SessionData'}, ...
                "DataLocation", {'Rawdata', 'Processed', 'Processed', 'Processed'}, "DataLocationUuid", {'a1', '', '', ''}, ...
                "Subfolder", {'', 'roi_data', '', ''}, "FileNameExpression", {'config', '', 'motion_corrected', ''}, ...
                "FileType", {'.json', '.mat', '.tif', '.mat'}, "FileAdapter", {'Default', 'Default', 'ImageStack', 'Default'}, ...
                "DataType", {'struct', 'RoiArray', 'ImageStack', 'struct'}, "Alias", {'', '', '', ''}, ...
                "IsDefault", {false, false, true, false}, "IsCustom", {true, true, false, false}, ...
                "IsInternal", {false, false, false, true}, "IsFavorite", {false, false, false, false});
            save(fullfile(folder, "configurations", "filepath_settings.mat"), "Data", "Preferences");

            % a pipeline with a task that has a method here, one that has not, one of the project's own, and a rule for new sessions
            tasks = struct("TaskNum", {1, 2, 3}, "TaskName", {'Extract signals', 'Plot stats', 'Note zoom'}, ...
                "TaskFunction", {'nansen.module.ophys.twophoton.sessionmethod.process.signalExtraction.extractSignals', ...
                'nansen.module.ophys.twophoton.sessionmethod.plot.plotImageStats', 'RatNav.sessionmethod.process.noteZoom'}, ...
                "OptionPresetSelection", {'Default', '', ''});
            Data = struct("Uuid", 'p1', "PipelineName", 'Signals', "PipelineTasks", tasks, ...
                "SessionProperties", struct("VariableName", 'sessionID', "Mode", 'contains', "Expression", 'm110'));
            Preferences = struct("SourceID", '', "DefaultPipeline", '');
            save(fullfile(folder, "configurations", "pipeline_settings.mat"), "Data", "Preferences");
            mkdir(fullfile(folder, "configurations", "custom_options"));
            OptionsEntries = struct("Name", {'Default', 'Fast'}, "Type", {'Preset', 'Custom'}, "Description", {'', ''}, ...
                "Options", {struct(), struct()});
            DefaultOptionsName = 'Default';
            save(fullfile(folder, "configurations", "custom_options", "normcorre.mat"), "OptionsEntries", "DefaultOptionsName");

            entries = table();
            entries.sessionID = {'m110-001'; 'm110-002'; 'm111-001'};
            entries.subjectID = {'m110'; 'm110'; ''};
            entries.Date = datetime(2025, 5, [23; 24; 25]);
            entries.Ignore = [false; true; false];
            entries.Description = {'Good'; ''; ''};
            entries.NumRois = int32([120; 0; 4]);
            entries.Quality = [0.8; NaN; 1];
            entries.Reviewed = {true; false; true};
            entries.DataLocation = repmat(struct("Uuid", 'a1', "RootUid", 'local'), 3, 1);
            note = @(author, when, type, title, text) struct("Author", author, "DateTime", when, "TimeStamp", '', ...
                "ObjectType", 'Session', "ObjectID", '', "Title", title, "Type", type, "Text", {text}, "Tags", {{}});
            entries.Notebook = { ...   % as dev keeps it: per row, a struct array of notes in a cell
                [note('ana', datetime(2025, 5, 23, 9, 0, 0), 'Important', 'Drift', 'Slow #drift'), ...
                 note('ben', datetime(2025, 5, 23, 12, 30, 0), 'Todo', 'Rerun', {'line one'; 'line two'})]; ...
                struct([]); ...
                note('ana', datetime(2025, 5, 25, 8, 0, 0), 'Question', 'Which subject?', '')};
            S = struct("MetaTableMembers", {entries.sessionID}, "MetaTableEntries", entries, ...
                "MetaTableVariables", {entries.Properties.VariableNames}, "IsMaster", true, ...
                "MetaTableName", 'Sessions', "MetaTableClass", 'nansen.metadata.type.Session', ...
                "ItemClassName", 'nansen.metadata.type.Session', "MetaTableIdVarname", 'sessionID', ...
                "MetaTableKey", 'k1', "FileName", 'sessions.mat', "VersionNumber", int64(3));
            save(fullfile(folder, "metadata", "tables", "sessions.mat"), "-struct", "S");
            catalogTable = table({'Sessions'}, true, VariableNames=["MetaTableName", "IsMaster"]);
            save(fullfile(folder, "metadata", "tables", "metatable_catalog.mat"), "catalogTable");

            % the project's own session method (dev's Module.getObjectMethodFolder), and a file there that is not one
            methods_ = fullfile(folder, "code", "+RatNav", "+sessionmethod");
            mkdir(fullfile(methods_, "+process"));
            lines = [
                "function varargout = noteZoom(sessionObject, varargin)"
                "%NOTEZOOM Write the zoom of the session's config in its raw folder."
                "    params = getDefaultParameters();"
                "    ATTRIBUTES = {'serial'};"
                "    attributes = nansen.session.SessionMethod.setAttributes(params, ATTRIBUTES{:});"
                "    if ~nargin && nargout > 0"
                "        varargout = {attributes};   return"
                "    end"
                "    params = utility.parsenvpairs(params, [], varargin);"
                "    config = sessionObject.loadData('SessionConfig');"
                "    folder = sessionObject.getSessionFolder('Rawdata');"
                "    fid = fopen(fullfile(folder, params.FileName), 'w');"
                "    fprintf(fid, '%d', config.zoom * params.Factor);"
                "    fclose(fid);"
                "end"
                ""
                "function params = getDefaultParameters()"
                "    params = struct();"
                "    params.FileName = 'zoom.txt'; % Written in the session's raw folder"
                "    params.Factor = 1;"
                "end"
                ];
            nansen.internal.writeText(fullfile(methods_, "+process", "noteZoom.m"), strjoin(lines', newline) + newline);
            nansen.internal.writeText(fullfile(methods_, "describe.m"), "function d = describe(s)" + newline + "    d = s;" + newline + "end" + newline);
        end
    end

    methods (Test)
        function exportReadsTheDevFiles(testCase)
            export = nansen.legacy.exportProject(testCase.Legacy);
            testCase.verifyEqual(string(export.project.shortName), "RatNav");
            locations = nansen.internal.asCellOfStructs(export.dataLocations);
            testCase.verifyEqual(string(cellfun(@(l) l.name, locations, UniformOutput=false)), ["Rawdata", "Processed"]);
            levels = nansen.internal.asCellOfStructs(locations{1}.subfolders);
            testCase.verifyEqual(string(levels{1}.ignoreList), "old");
            tables = nansen.internal.asCellOfStructs(export.tables);
            testCase.verifyNumElements(tables, 1);
            sessions = tables{1};
            testCase.verifyEqual(string(sessions.entityClass), "session");
            columns = nansen.internal.asCellOfStructs(sessions.columns);
            types = string(cellfun(@(c) c.dataType, columns, UniformOutput=false));
            names = string(cellfun(@(c) c.name, columns, UniformOutput=false));
            testCase.verifyEqual(names, ["sessionID", "subjectID", "Date", "Ignore", "Description", "NumRois", "Quality", "Reviewed"]);
            testCase.verifyEqual(types, ["string", "string", "date", "boolean", "string", "integer", "number", "boolean"]);
            testCase.verifyEqual(string(sessions.skippedColumns), "DataLocation");   % Notebook is not skipped
            notes = nansen.internal.asCellOfStructs(sessions.notes);
            testCase.verifyEqual(cellfun(@(n) n.row, notes), [0, 0, 2]);
            testCase.verifyEqual(string(notes{1}.createdAt), "2025-05-23T09:00:00");
            testCase.verifyEqual(string(notes{2}.text), "line one" + newline + "line two");
            testCase.verifyEqual(string(notes{3}.type), "Question");
            rows = nansen.internal.asCellOfStructs(sessions.rows);
            testCase.verifyEqual(string(rows{1}.Date), "2025-05-23");
            testCase.verifyEmpty(rows{2}.Description);   % empty text is null
            testCase.verifyEmpty(rows{2}.Quality);       % NaN is null
            methods_ = nansen.internal.asCellOfStructs(export.sessionMethods);   % the project's own, with their text
            testCase.verifyEqual(string(cellfun(@(m) m.file, methods_, UniformOutput=false)), ...
                ["code/+RatNav/+sessionmethod/+process/noteZoom.m", "code/+RatNav/+sessionmethod/describe.m"]);
            testCase.verifyTrue(startsWith(string(methods_{1}.text), "function varargout = noteZoom("));
        end

        function exportWritesJsonForPython(testCase)
            file = fullfile(testCase.Folder, "export.json");
            nansen.legacy.exportProject(testCase.Legacy, File=file);
            document = nansen.readDocument(file);
            testCase.verifyEqual(string(document.schemaType), "nansen.legacyExport");
        end

        function importMakesAProjectThatScans(testCase)
            target = fullfile(testCase.Folder, "imported");
            report = nansen.legacy.importProject(testCase.Legacy, target);
            testCase.verifyEqual(report.rows, struct("subject", 0, "session", 2));
            % MotionCorrected, an ImageStack of .tif files, is kept through the ophys module's TIFF adapter
            testCase.verifyEqual(string(report.dataVariables), ["SessionConfig", "RoiArray", "MotionCorrected"]);
            testCase.verifyFalse(any(contains(string(report.warnings), "'MotionCorrected'")));
            testCase.verifyTrue(any(contains(string(report.warnings), "1 row(s) with no subject_id or session_id")));
            testCase.verifyEqual(report.notes, struct("session", 2));
            testCase.verifyEqual(string(report.pipelines), "legacy.signals");   % with extractSignals; plotImageStats has no method here
            testCase.verifyTrue(any(contains(string(report.warnings), "task 'Plot stats'")));
            testCase.verifyEqual(string(report.methods), "legacy.note_zoom");   % the project's own session method
            testCase.verifyTrue(any(contains(string(report.warnings), "session method code/+RatNav/+sessionmethod/describe.m: ")));
            testCase.verifyTrue(any(contains(string(report.warnings), "option presets of normcorre (Fast) are not carried over")));
            testCase.verifyTrue(any(contains(string(report.warnings), "1 note(s) on rows that were left out")));

            project = nansen.Project.open(target);
            testCase.verifyEqual(project.Name, "RatNav");
            testCase.verifyEqual(project.EntityTypes, ["subject", "session"]);   % subject: an empty table to sync into
            scan = project.scan();
            entities = project.entities("session", scan);
            ids = string(cellfun(@(e) e.Key.session_id, entities, UniformOutput=false));
            testCase.verifyEqual(sort(ids), ["m110-001", "m110-002", "m111-001"]);   % m112_old is ignored
            first = entities{ids == "m110-001"};
            testCase.verifyEqual(first.Row.description, "Good");
            testCase.verifyEqual(first.Row.NumRois, 120);
            testCase.verifyEqual(project.load(first, "SessionConfig"), struct("zoom", 2));
            testCase.verifyEmpty(entities{ids == "m111-001"}.Row);
            notes = project.notebook("session").notes();   % newest first
            testCase.verifyEqual(cellfun(@(n) string(n.type), notes), ["todo", "important"]);
            testCase.verifyEqual(string(notes{2}.tags), "drift");
            testCase.verifyEqual(string(notes{2}.key.session_id), "m110-001");

            % dev's session method runs as it is: dev's data location and variable names, and its options
            steps = nansen.internal.asCellOfStructs(project.pipeline("legacy.signals").steps);
            testCase.verifyEqual(string(cellfun(@(s) s.method, steps, UniformOutput=false)), ["ophys.extract_signals", "legacy.note_zoom"]);
            method = project.method("legacy.note_zoom");
            testCase.verifyTrue(isfile(fullfile(target, "matlab", "+RatNav", "+sessionmethod", "+process", "noteZoom.m")));
            testCase.verifyEqual(string(method.Document.implementations.matlab), "RatNav.sessionmethod.process.noteZoom");
            project.run("legacy.note_zoom", {first}, Options=struct("Factor", 3));
            written = fullfile(testCase.Folder, "raw", "m110", "2025_05_23", "session-m110-001", "zoom.txt");
            testCase.verifyEqual(string(nansen.internal.readText(written)), "6");
        end

        function importNeedsAnEmptyFolder(testCase)
            target = fullfile(testCase.Folder, "busy");
            mkdir(target);
            nansen.internal.writeText(fullfile(target, "x.txt"), "");
            testCase.verifyError(@() nansen.legacy.importProject(testCase.Legacy, target), "nansen:FolderNotEmpty");
        end

        function indexRangesBecomeSlices(testCase)
            cases = ["1:end", ":"; "1:5", ":5"; "3:end", "2:"; "end-3:end", "-4:"; "4", "3:4"; ...
                "end-2:end-1", "-3:-1"; " 2 : 6 ", "1:6"; "end", "-1:"];
            for i = 1:size(cases, 1)
                testCase.verifyEqual(nansen.legacy.indexToSlice(cases(i, 1)), cases(i, 2), cases(i, 1));
            end
            for expression = ["[1:3 5:7]", "0:4", "5:2", "1:2:9", "a:b", ""]
                testCase.verifyTrue(ismissing(nansen.legacy.indexToSlice(expression)), expression);
            end
        end
    end
end
