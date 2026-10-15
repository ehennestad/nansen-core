classdef EntitiesTest < matlab.unittest.TestCase
%EntitiesTest Projects with a dataset: scanning a real folder, joining, syncing, generating paths

    properties
        Folder string
        Project
    end

    methods (TestMethodSetup)
        function makeProject(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            testCase.Folder = fixture.Folder;
            nansen.internal.writeText(fullfile(testCase.Folder, "dataset.dsm.json"), EntitiesTest.datasetJson());
            for path = ["sub-m1/ses-m1-001/movie.tif", "sub-m1/ses-m1-002/movie.tif", "sub-m2/ses-m2-001/notes.txt"]
                target = fullfile(testCase.Folder, "data", "raw", path);
                mkdir(fileparts(target));
                nansen.internal.writeText(target, "x");
            end
            mkdir(fullfile(testCase.Folder, "data", "processed", "m1", "m1-001"));
            testCase.Project = nansen.Project.create(testCase.Folder, "Pilot", Dataset="dataset.dsm.json");
            testCase.Project.addEntityType("subject");
            testCase.Project.addEntityType("session");
        end
    end

    methods (Static)
        function text = datasetJson()
            text = fileread(fullfile(fileparts(fileparts(fileparts(mfilename("fullpath")))), "testdata", "entities-dataset.dsm.json"));
        end
    end

    methods (Static)
        function logProfile(testCase, label)
            % Where the time went in the last profile: functions by their own time (without callees), and
            % nansen and dsm functions by total time, for finding slow spots from CI logs
            info = profile("info");
            profile("clear");
            entries = info.FunctionTable;
            if isempty(entries)
                return
            end
            self = zeros(1, numel(entries));
            for k = 1:numel(entries)
                children = entries(k).Children;
                self(k) = entries(k).TotalTime - sum([children.TotalTime]);
            end
            [~, bySelf] = sort(self, "descend");
            lines = "by own time:";
            for k = bySelf(1:min(20, numel(bySelf)))
                lines(end + 1) = sprintf("%8.2f s %8d calls  %s", self(k), entries(k).NumCalls, entries(k).FunctionName); %#ok<AGROW>
            end
            ours = find(startsWith(string({entries.FunctionName}), ["nansen.", "dsm.", "Project>", "Dataset>", ...
                "Scan>", "EntityTable>", "Api>", "Entity>", "Config>", "WalkResult>", "Listing>"]));
            [~, order] = sort([entries(ours).TotalTime], "descend");
            lines(end + 1) = "nansen and dsm by total time:";
            for k = ours(order(1:min(20, numel(order))))
                lines(end + 1) = sprintf("%8.2f s %8d calls  %s", entries(k).TotalTime, entries(k).NumCalls, entries(k).FunctionName); %#ok<AGROW>
            end
            testCase.log(1, "profile of " + label + newline + strjoin(lines, newline));
        end
    end

    methods (Test)
        function largeProjectTimings(testCase)
            % 5,000 sessions of 50 subjects on disk; the times are logged, so CI shows how the join scales.
            % With NANSEN_PROFILE=1 the scan and entities.list are run once more under the profiler,
            % and the functions taking the most time are logged too.
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            folder = string(fixture.Folder);
            config = struct("schemaVersion", '0.1.0', ...
                "entityTypes", {{struct("name", 'subject', "identifierRef", 'subject_id'), struct("name", 'session', "identifierRef", 'session_id')}}, ...
                "metadataDefinitions", struct( ...
                    "subject_id", struct("name", 'subject_id', "dataType", 'string', "ofEntity", 'subject'), ...
                    "session_id", struct("name", 'session_id', "dataType", 'string', "ofEntity", 'session')), ...
                "dataLocations", {{struct("identifier", 'raw', "displayName", 'Raw', "dataCategory", 'raw', "access", 'read', ...
                    "sourceType", 'filesystem', "filesystemSource", struct( ...
                        "rootStoragePaths", {{struct("identifier", 'here', "path", 'data')}}, ...
                        "entityLayout", {{struct("name", 'subjects', "entityType", 'subject', "pathComponentTemplate", 'subject-{subject_id}'), ...
                                          struct("name", 'sessions', "entityType", 'session', "pathComponentTemplate", 'session-{session_id}')}}, ...
                        "metadataMapping", {{struct("metadataRef", 'subject_id', "extraction", struct("method", 'regex', "pattern", '^subject-(.+)$', "entityLayoutLevel", 'subjects')), ...
                                             struct("metadataRef", 'session_id', "extraction", struct("method", 'regex', "pattern", '^session-(.+)$', "entityLayoutLevel", 'sessions'))}}))}});
            nansen.internal.writeJson(fullfile(folder, "dataset.dsm.json"), config);
            for s = 0:49
                subject = sprintf("m%03d", s);
                for k = 0:99
                    mkdir(fullfile(folder, "data", "subject-" + subject, sprintf("session-%s-%03d", subject, k)));
                end
            end
            project = nansen.Project.create(fullfile(folder, "p"), "P", Dataset="../dataset.dsm.json");
            project.addModule("core");
            project.addEntityType("subject", [], Fragments="core.notes");
            project.addEntityType("session", [], Fragments="core.notes");
            times = struct();
            dataset = project.dataset();
            started = tic; listing = dataset.listing(); times.listing = toc(started);
            started = tic; dsm.walk(dataset.Config, listing, dsm.ExtractorRegistry()); times.walk = toc(started);
            started = tic; scan = project.scan(); times.scan = toc(started);
            profiling = getenv("NANSEN_PROFILE") == "1";
            if profiling
                profile("on");
                project.scan();
                profile("off");
                EntitiesTest.logProfile(testCase, "scan");
            end
            started = tic; project.sync("session", scan); times.sync = toc(started);
            started = tic; entities = project.entities("session", scan); times.entities = toc(started);
            testCase.verifyNumElements(entities, 5000);
            api = nansen.Api(Project=project);
            request = '{"id": 1, "method": "entities.list", "params": {"entityType": "session"}}';
            started = tic;
            response = jsondecode(char(api.handleJson(request)));
            times.list = toc(started);
            if profiling
                profile("on");
                api.handleJson(request);
                profile("off");
                EntitiesTest.logProfile(testCase, "entities.list");
            end
            testCase.verifyNumElements(response.result.rows, 5000);
            testCase.log(1, sprintf("5000 sessions: listing %.2f s, walk %.2f s, scan %.2f s, sync %.2f s, join %.2f s, entities.list %.2f s", ...
                times.listing, times.walk, times.scan, times.sync, times.entities, times.list));
        end

        function keyComesFromTheDataset(testCase)
            testCase.verifyEqual(testCase.Project.table("subject").Key, "subject_id");
            testCase.verifyEqual(testCase.Project.table("session").Key, ["subject_id", "session_id"]);
        end

        function scanReadsTheFoldersAndCaches(testCase)
            scan = testCase.Project.scan();
            testCase.verifyTrue(isfile(testCase.Project.scanPath()));
            ids = sort(string(cellfun(@(r) r.identity.session_id, scan.recordsOf("session"), UniformOutput=false)));
            testCase.verifyEqual(ids, ["m1-001", "m1-002", "m2-001"]);
            testCase.verifyEqual(numel(testCase.Project.lastScan().Records), numel(scan.Records));
        end

        function aRootOnARemovableDriveIsFoundWhereItIsMountedNow(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            testCase.verifyEqual(nansen.internal.pathInVolume("/Volumes/LabDisk/data/raw", "LabDisk"), "data/raw");
            testCase.verifyEqual(nansen.internal.pathInVolume("E:\data\raw", "LabDisk"), "data/raw");
            testCase.verifyTrue(ismissing(nansen.internal.pathInVolume("/somewhere/else", "LabDisk")));
            mkdir(fullfile(fixture.Folder, "mounts", "LabDisk", "data", "raw", "sub-m1"));
            config = struct("schemaVersion", '0.1.0', ...
                "entityTypes", {{struct("name", 'subject', "identifierRef", 'subject_id')}}, ...
                "metadataDefinitions", struct("subject_id", struct("name", 'subject_id', "dataType", 'string', "ofEntity", 'subject')), ...
                "dataLocations", {{struct("identifier", 'raw', "displayName", 'Raw', "dataCategory", 'raw', "sourceType", 'filesystem', ...
                    "filesystemSource", struct( ...
                        "rootStoragePaths", {{struct("identifier", 'disk', "path", '/Volumes/LabDisk/data/raw', "volumeName", 'LabDisk')}}, ...
                        "entityLayout", {{struct("name", 'subjects', "entityType", 'subject', "matchPattern", '^sub-.+$')}}, ...
                        "metadataMapping", {{struct("metadataRef", 'subject_id', "extraction", ...
                            struct("method", 'regex', "pattern", '^sub-(.+)$', "entityLayoutLevel", 0))}}))}});
            nansen.internal.writeJson(fullfile(fixture.Folder, "dataset.dsm.json"), config);
            dataset = nansen.Dataset.load(fullfile(fixture.Folder, "dataset.dsm.json"));
            roots = dataset.roots();
            testCase.verifyFalse(roots(1).Available);
            testCase.applyFixture(matlab.unittest.fixtures.EnvironmentVariableFixture("NANSEN_VOLUME_ROOTS", fullfile(fixture.Folder, "mounts")));
            roots = dataset.roots();
            testCase.verifyTrue(roots(1).Available);
            testCase.verifyEqual(string(roots(1).Path), string(fullfile(fixture.Folder, "mounts", "LabDisk", "data", "raw")));
            testCase.verifyEqual(numel(dataset.scan([]).Records), 1);
        end

        function environmentSelectsRoots(testCase)
            lab = nansen.Project.open(testCase.Folder, Environment="lab");
            roots = lab.dataset().roots();
            testCase.verifyEqual([roots.DataLocation], "raw");
            testCase.verifyFalse(roots.Available);
            testCase.verifyEmpty(lab.scan([], Save=false).Records);
        end

        function entitiesJoinAndSync(testCase)
            project = testCase.Project;
            project.scan();
            sessions = project.entities("session");
            testCase.verifyEqual(cellfun(@(e) e.inTable(), sessions), false(1, 3));
            m1 = project.entity("session", struct("session_id", "m1-001"));
            location = m1.location("processed");
            testCase.verifyEqual(string(location.paths), "m1/m1-001/");
            testCase.verifyEqual(m1.files("raw", "movie"), "sub-m1/ses-m1-001/movie.tif");
            testCase.verifyEqual(m1.attributes().session_number, 1);
            added = project.sync("session");
            testCase.verifyEqual(numel(added), 3);
            testCase.verifyTrue(all(cellfun(@(e) e.inTable() && e.inStore(), project.entities("session"))));
            testCase.verifyEmpty(project.sync("session"));
        end

        function rowsWithoutRecordsAreKept(testCase)
            project = testCase.Project;
            project.scan();
            project.sync("subject");
            table = project.table("subject");
            table.addRow(struct("subject_id", "m9"));
            table.write()
            ghost = project.entity("subject", struct("subject_id", "m9"));
            testCase.verifyTrue(ghost.inTable());
            testCase.verifyFalse(ghost.inStore());
        end

        function foldersMatchedToEntitiesByHand(testCase)
            project = testCase.Project;
            raw = fullfile(testCase.Folder, "data", "raw");
            mkdir(fullfile(raw, "sub-m1", "odd"));
            nansen.internal.writeText(fullfile(raw, "sub-m1", "odd", "movie.tif"), "x");
            mkdir(fullfile(raw, "Mouse2", "ses-m2-009"));
            nansen.internal.writeText(fullfile(raw, "Mouse2", "ses-m2-009", "movie.tif"), "x");
            scan = project.scan();
            paths = sort(string(cellfun(@(u) u.path, scan.Unmatched, UniformOutput=false)));
            testCase.verifyEqual(paths, ["Mouse2/", "sub-m1/odd/"]);
            dataset = project.dataset();
            [entityType, key] = dataset.suggestedKey("raw", "here", "sub-m1/odd/");
            testCase.verifyEqual(entityType, 'session');
            testCase.verifyEqual(key.subject_id, 'm1');
            testCase.verifyTrue(isnan(key.session_id));
            [entityType, key] = dataset.suggestedKey("raw", "here", "sub-m1/odd");   % a file where a folder is expected
            testCase.verifyTrue(isnan(entityType) && isnan(key));

            assignment = project.assignEntry("raw", "sub-m1\odd", struct("subject_id", 'm1', "session_id", ' m1-002 '));
            testCase.verifyEqual(assignment.path, 'sub-m1/odd/');
            testCase.verifyEqual(assignment.entityType, 'session');
            testCase.verifyEqual(assignment.key, struct("subject_id", 'm1', "session_id", 'm1-002'));
            project.assignEntry("raw", "Mouse2/", struct("subject_id", 'm2'));
            testCase.verifyEqual(string(cellfun(@(a) a.path, project.assignments(), UniformOutput=false)), ["sub-m1/odd/", "Mouse2/"]);
            scan = project.scan();
            testCase.verifyEmpty(scan.Unmatched);
            % a folder given to a session found elsewhere: one more folder of it, with its files
            m1 = project.entity("session", struct("session_id", "m1-002"));
            testCase.verifyEqual(string(m1.location("raw").paths)', ["sub-m1/odd/", "sub-m1/ses-m1-002/"]);
            testCase.verifyEqual(m1.files("raw", "movie"), ["sub-m1/odd/movie.tif", "sub-m1/ses-m1-002/movie.tif"]);
            testCase.verifyTrue(ismember("duplicate-entity", m1.issueCodes()));
            % a subject's folder: what is below it is walked as usual, with the subject as its parent
            m2 = project.entity("session", struct("session_id", "m2-009"));
            testCase.verifyEqual(string(m2.Key.subject_id), "m2");
            testCase.verifyEqual(string(m2.location("raw").paths), "Mouse2/ses-m2-009/");
            testCase.verifyEqual(m2.attributes().session_number, 9);
            testCase.verifyEqual(numel(project.entities("session")), 4);

            removed = project.unassignEntry("raw", "sub-m1/odd");
            testCase.verifyEqual(removed.key.session_id, 'm1-002');
            testCase.verifyError(@() project.unassignEntry("raw", "sub-m1/odd/"), "nansen:UnknownAssignment");
            testCase.verifyError(@() project.assignEntry("raw", "sub-m1/odd/", struct("subject_id", 'm1')), "nansen:InvalidParams");
            testCase.verifyError(@() project.assignEntry("lab", "sub-m1/", struct("subject_id", 'm1')), "nansen:UnknownLocation");
            scan = project.scan();
            testCase.verifyEqual(string(cellfun(@(u) u.path, scan.Unmatched, UniformOutput=false)), "sub-m1/odd/");
        end

        function generatePath(testCase)
            dataset = testCase.Project.dataset();
            testCase.verifyEqual(dataset.generatePath("processed", "session", ...
                struct("subject_id", "m2", "session_id", "m2-001")), "m2/m2-001/");
            testCase.verifyError(@() dataset.generatePath("raw", "session", ...
                struct("subject_id", "m2", "session_id", "m2-001")), "nansen:GenerationFailed");
        end
    end
end
