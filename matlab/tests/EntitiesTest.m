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

    methods (Test)
        function largeProjectTimings(testCase)
            % 5,000 sessions of 50 subjects on disk; the times are logged, so CI shows how the join scales.
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
            started = tic; scan = project.scan(); times.scan = toc(started);
            started = tic; project.sync("session", scan); times.sync = toc(started);
            started = tic; entities = project.entities("session", scan); times.entities = toc(started);
            testCase.verifyNumElements(entities, 5000);
            api = nansen.Api(Project=project);
            started = tic;
            response = jsondecode(char(api.handleJson('{"id": 1, "method": "entities.list", "params": {"entityType": "session"}}')));
            times.list = toc(started);
            testCase.verifyNumElements(response.result.rows, 5000);
            testCase.log(1, sprintf("5000 sessions: scan %.2f s, sync %.2f s, join %.2f s, entities.list %.2f s", ...
                times.scan, times.sync, times.entities, times.list));
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

        function generatePath(testCase)
            dataset = testCase.Project.dataset();
            testCase.verifyEqual(dataset.generatePath("processed", "session", ...
                struct("subject_id", "m2", "session_id", "m2-001")), "m2/m2-001/");
            testCase.verifyError(@() dataset.generatePath("raw", "session", ...
                struct("subject_id", "m2", "session_id", "m2-001")), "nansen:GenerationFailed");
        end
    end
end
