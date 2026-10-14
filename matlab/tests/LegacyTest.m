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
            S = struct("MetaTableMembers", {entries.sessionID}, "MetaTableEntries", entries, ...
                "MetaTableVariables", {entries.Properties.VariableNames}, "IsMaster", true, ...
                "MetaTableName", 'Sessions', "MetaTableClass", 'nansen.metadata.type.Session', ...
                "ItemClassName", 'nansen.metadata.type.Session', "MetaTableIdVarname", 'sessionID', ...
                "MetaTableKey", 'k1', "FileName", 'sessions.mat', "VersionNumber", int64(3));
            save(fullfile(folder, "metadata", "tables", "sessions.mat"), "-struct", "S");
            catalogTable = table({'Sessions'}, true, VariableNames=["MetaTableName", "IsMaster"]);
            save(fullfile(folder, "metadata", "tables", "metatable_catalog.mat"), "catalogTable");
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
            testCase.verifyEqual(string(sessions.skippedColumns), "DataLocation");
            rows = nansen.internal.asCellOfStructs(sessions.rows);
            testCase.verifyEqual(string(rows{1}.Date), "2025-05-23");
            testCase.verifyEmpty(rows{2}.Description);   % empty text is null
            testCase.verifyEmpty(rows{2}.Quality);       % NaN is null
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
            testCase.verifyEqual(string(report.dataVariables), ["SessionConfig", "RoiArray"]);
            testCase.verifyTrue(any(contains(string(report.warnings), "'MotionCorrected'")));
            testCase.verifyTrue(any(contains(string(report.warnings), "1 row(s) with no subject_id or session_id")));

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
