classdef ApiTest < matlab.unittest.TestCase
%ApiTest The MATLAB Api over JSON text, as the uihtml frontend uses it

    methods (Test)
        function dispatchErrorsAreCoded(testCase)
            api = nansen.Api();
            response = jsondecode(char(api.handleJson('{"id": 1}')));
            testCase.verifyEqual(string(response.error.code), "invalid-request");
            response = jsondecode(char(api.handleJson('not json')));
            testCase.verifyEqual(string(response.error.code), "invalid-request");
            response = jsondecode(char(api.handleJson('{"id": 2, "method": "no.such"}')));
            testCase.verifyEqual(string(response.error.code), "unknown-api-method");
            testCase.verifyEqual(response.id, 2);
            response = jsondecode(char(api.handleJson('{"id": 3, "method": "project.info"}')));
            testCase.verifyEqual(string(response.error.code), "no-project");
        end

        function sameMethodsAsTheProtocol(testCase)
            % The methods table of docs/reference/protocol.md, which Python's API is checked against too
            api = nansen.Api();
            info = jsondecode(char(api.handleJson('{"id": 1, "method": "app.info"}'))).result;
            text = nansen.internal.readText(fullfile(nansen.internal.repoRoot(), "docs", "reference", "protocol.md"));
            expected = strings(1, 0);
            for line = reshape(splitlines(string(text)), 1, [])
                first = regexp(char(line), '^\| ([^|]+) \|', "tokens", "once");
                if isempty(first)
                    continue
                end
                for found = regexp(first{1}, '`([a-zA-Z]+\.[a-zA-Z]+)`', "tokens")
                    expected(end + 1) = string(found{1}{1}); %#ok<AGROW>
                end
            end
            testCase.verifyEqual(sort(string(info.methods))', sort(unique(expected)));
            testCase.verifyEqual(string(info.language), "matlab");
        end

        function eventsReachListeners(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            catalog = nansen.Catalog(fullfile(fixture.Folder, "catalog.json"));
            api = nansen.Api(Catalog=catalog);
            api.subscribe(@(message) assignin("base", "nansenApiTestEvent", message));
            request = struct("id", 1, "method", "project.create", "params", ...
                struct("path", fullfile(fixture.Folder, "p"), "name", "Pilot", "modules", {{'core'}}));
            response = api.handle(request);
            testCase.verifyEqual(string(response.result.name), "Pilot");
            message = evalin("base", "nansenApiTestEvent");
            evalin("base", "clear nansenApiTestEvent");
            testCase.verifyEqual(string(message.event), "project");
            projects = api.handle(struct("id", 2, "method", "catalog.list")).result;
            testCase.verifyEqual(string(projects{1}.name), "Pilot");
        end

        function revealShowsFoldersInsideTheProject(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            project = nansen.demo.create(fullfile(fixture.Folder, "demo"));
            api = nansen.Api(Project=project);
            api.OpenFolder = @(folder) assignin("base", "nansenApiTestOpened", folder);
            response = api.handle(struct("id", 1, "method", "files.reveal", "params", struct("path", "tables/session.csv")));
            testCase.verifyTrue(response.result.exists);
            opened = evalin("base", "nansenApiTestOpened");
            evalin("base", "clear nansenApiTestOpened");
            testCase.verifyEqual(string(opened), string(fullfile(project.Folder, "tables")));
            response = api.handle(struct("id", 2, "method", "files.resolve", "params", struct("path", "../x")));
            testCase.verifyEqual(string(response.error.code), "invalid-params");
        end

        function theDatasetConfigIsEditedAsText(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            project = nansen.demo.create(fullfile(fixture.Folder, "demo"));
            api = nansen.Api(Project=project);
            configPath = fullfile(project.Folder, "dataset.dsm.json");
            got = api.handle(struct("id", 1, "method", "dataset.get")).result;
            testCase.verifyEqual(string(got.path), "dataset.dsm.json");
            testCase.verifyEqual(string(got.text), string(nansen.internal.readText(configPath)));

            edited = replace(string(got.text), '"displayName": "Processed"', '"displayName": "Processed data"');
            info = api.handle(struct("id", 2, "method", "dataset.save", "params", struct("text", edited))).result;
            locations = nansen.internal.asCellOfStructs(info.dataset.locations);
            testCase.verifyEqual(cellfun(@(l) string(l.title), locations), ["Raw two-photon data", "Processed data"]);
            testCase.verifyEqual(string(nansen.internal.readText(configPath)), edited);   % as written

            % A config DSM accepts, but whose identity no longer fits the session table, is not kept
            changed = replace(edited, '"identifierRef": "session_id"', '"identifierRef": "session_date"');
            response = api.handle(struct("id", 3, "method", "dataset.save", "params", struct("text", changed)));
            testCase.verifyEqual(string(response.error.code), "key-mismatch");
            testCase.verifyEqual(string(nansen.internal.readText(configPath)), edited);
            response = api.handle(struct("id", 4, "method", "dataset.save", "params", struct("text", "{")));
            testCase.verifyEqual(string(response.error.code), "dataset-invalid");
            testCase.verifyEqual(string(nansen.internal.readText(configPath)), edited);
            rows = api.handle(struct("id", 5, "method", "entities.list", "params", struct("entityType", "session"))).result.rows;
            testCase.verifyNotEmpty(rows);
        end

        function entitiesAreSentToTheWorkspace(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            project = nansen.demo.create(fullfile(fixture.Folder, "demo"));
            api = nansen.Api(Project=project);
            api.SendToWorkspace = @(name, value) assignin("base", "nansenApiTestSent", {name, value});
            testCase.addTeardown(@() evalin("base", "clear nansenApiTestSent"));
            info = api.handle(struct("id", 1, "method", "app.info")).result;
            testCase.verifyTrue(info.workspace);
            rows = api.handle(struct("id", 2, "method", "entities.list", "params", struct("entityType", "session"))).result.rows;
            rows = nansen.internal.asCellOfStructs(rows);
            keys = {rows{1}.key, rows{2}.key};
            result = api.handle(struct("id", 3, "method", "workspace.send", "params", ...
                struct("entityType", "session", "keys", {keys}, "name", "picked"))).result;
            testCase.verifyEqual(string(result.name), "picked");
            testCase.verifyEqual(result.count, 2);
            sentValue = evalin("base", "nansenApiTestSent");
            testCase.verifyEqual(string(sentValue{1}), "picked");
            testCase.verifyClass(sentValue{2}{1}, "nansen.Entity");
            testCase.verifyEqual(numel(sentValue{2}), 2);
            response = api.handle(struct("id", 4, "method", "workspace.send", "params", struct("entityType", "session", "name", "not valid")));
            testCase.verifyEqual(string(response.error.code), "invalid-params");
        end

        function filesOpenMethodsEditAndDataSend(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            project = nansen.demo.create(fullfile(fixture.Folder, "demo"));
            api = nansen.Api(Project=project);
            api.OpenFile = @(path) assignin("base", "nansenApiTestOpened", string(path));
            api.EditFile = @(path) assignin("base", "nansenApiTestEdited", string(path));
            api.SendToWorkspace = @(name, value) assignin("base", "nansenApiTestSent", {name, value});
            testCase.addTeardown(@() evalin("base", "clear nansenApiTestOpened nansenApiTestEdited nansenApiTestSent"));
            call = @(method, params) api.handle(struct("id", 1, "method", method, "params", params));

            result = call("files.open", struct("path", "project.nansen.json")).result;
            testCase.verifyTrue(result.exists);
            testCase.verifyTrue(endsWith(evalin("base", "nansenApiTestOpened"), "project.nansen.json"));

            call("methods.create", struct("id", "count_frames", "entityType", "session"));
            result = call("methods.edit", struct("methodId", "count_frames")).result;
            testCase.verifyEqual(string(result.language), "matlab");
            testCase.verifyTrue(endsWith(evalin("base", "nansenApiTestEdited"), "count_frames.m"));
            result = call("methods.edit", struct("methodId", "count_frames", "language", "python")).result;
            testCase.verifyTrue(endsWith(string(result.path), "count_frames.py"));
            result = call("methods.edit", struct("methodId", "core.wait")).result;
            testCase.verifyTrue(endsWith(string(result.path), "nansenCoreWait.m"));

            rows = nansen.internal.asCellOfStructs(call("entities.list", struct("entityType", "session")).result.rows);
            row = rows{find(cellfun(@(r) ~isequal(nansen.internal.getField(r.values, "ignore", false), true), rows), 1)};
            result = call("data.send", struct("entityType", "session", "key", row.key, "variable", "motion_corrected", "name", "mc")).result;
            testCase.verifyEqual(string(result.name), "mc");
            sent = evalin("base", "nansenApiTestSent");
            testCase.verifyEqual(string(sent{1}), "mc");
            testCase.verifyNotEmpty(sent{2});
        end

        function projectsAreRenamedMovedAndDeleted(testCase)
            folder = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            catalog = nansen.Catalog(fullfile(folder, "catalog.json"));
            catalog.add(nansen.Project.create(fullfile(folder, "one"), "One"));
            catalog.add(nansen.Project.create(fullfile(folder, "two"), "Two"));
            api = nansen.Api(Catalog=catalog, Project=nansen.Project.open(fullfile(folder, "one")));
            call = @(method, params) api.handle(struct("id", 1, "method", method, "params", params));
            before = nansen.internal.readText(fullfile(folder, "one", "project.nansen.json"));
            call("catalog.rename", struct("path", fullfile(folder, "one"), "name", "First"));
            testCase.verifyEqual(api.Project.Name, "First");   % the open one, read again
            testCase.verifyEqual(string(nansen.internal.readText(fullfile(folder, "one", "project.nansen.json"))), ...
                replace(string(before), """One""", """First"""));
            response = call("catalog.rename", struct("path", fullfile(folder, "one"), "name", "no good"));
            testCase.verifyEqual(string(response.error.code), "invalid-params");
            response = call("catalog.move", struct("path", fullfile(folder, "one"), "newPath", fullfile(folder, "moved")));
            testCase.verifyEqual(string(response.error.code), "invalid-params");   % open
            call("catalog.move", struct("path", fullfile(folder, "two"), "newPath", fullfile(folder, "archive", "two")));
            testCase.verifyTrue(isfile(fullfile(folder, "archive", "two", "project.nansen.json")));
            testCase.verifyFalse(isfolder(fullfile(folder, "two")));
            response = call("catalog.remove", struct("path", fullfile(folder, "one"), "deleteFolder", true));
            testCase.verifyEqual(string(response.error.code), "invalid-params");   % open
            left = call("catalog.remove", struct("path", fullfile(folder, "archive", "two"), "deleteFolder", true)).result;
            left = nansen.internal.asCellOfStructs(left);
            testCase.verifyEqual(string(cellfun(@(p) string(p.name), left)), "First");
            testCase.verifyFalse(isfolder(fullfile(folder, "archive", "two")));
        end

        function editedRowsAreSavedIntoTheDataFolders(testCase)
            folder = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            catalog = nansen.Catalog(fullfile(folder, "catalog.json"));
            api = nansen.Api(Catalog=catalog, Project=nansen.demo.create(fullfile(folder, "demo")));
            call = @(method, params) api.handle(struct("id", 1, "method", method, "params", params));
            rows = nansen.internal.asCellOfStructs(call("entities.list", struct("entityType", "session")).result.rows);
            key = rows{1}.key;
            detail = call("entities.get", struct("entityType", "session", "key", key)).result;
            locations = nansen.internal.asCellOfStructs(detail.locations);
            folders = strings(1, 0);
            for i = 1:numel(locations)
                for p = reshape(string(locations{i}.paths), 1, [])
                    resolved = call("files.resolve", struct("dataLocation", locations{i}.dataLocationIdentifier, "path", p)).result;
                    if resolved.isFolder
                        folders(end + 1) = string(resolved.path); %#ok<AGROW>
                    end
                end
            end
            testCase.assertNotEmpty(folders);
            call("entities.update", struct("entityType", "session", "key", key, "values", struct("description", "first")));
            testCase.verifyFalse(any(arrayfun(@(f) isfile(fullfile(f, "session_info.json")), folders)));   % off unless asked for
            catalog.saveSettings(struct("tables", struct("saveToDataFolders", true)));
            call("entities.update", struct("entityType", "session", "key", key, "values", struct("description", "second")));
            for f = folders   % dev's AutosaveMetadataToDataFolders
                saved = jsondecode(nansen.internal.readText(fullfile(f, "session_info.json")));
                testCase.verifyEqual(string(saved.description), "second");
                testCase.verifyEqual(string(saved.session_id), string(key.session_id));
            end
        end

        function anyFileGoesToTheWorkspace(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            project = nansen.demo.create(fullfile(fixture.Folder, "demo"));
            api = nansen.Api(Project=project);
            api.SendToWorkspace = @(name, value) assignin("base", "nansenApiTestFile", {name, value});
            testCase.addTeardown(@() evalin("base", "clear nansenApiTestFile"));
            result = api.handle(struct("id", 1, "method", "files.send", "params", struct("path", "project.nansen.json"))).result;
            testCase.verifyEqual(string(result.name), "project_nansen");
            testCase.verifyEqual(string(result.adapter), "json");   % the first adapter naming .json
            sent = evalin("base", "nansenApiTestFile");
            testCase.verifyEqual(string(sent{1}), "project_nansen");
            testCase.verifyEqual(string(sent{2}.name), project.Name);
            result = api.handle(struct("id", 2, "method", "files.send", "params", struct("path", "tables/session.csv", "name", "sessions"))).result;
            testCase.verifyEqual(string(result.adapter), "csv");
            nansen.internal.writeText(fullfile(project.Folder, "x.unknown"), "?");
            response = api.handle(struct("id", 3, "method", "files.send", "params", struct("path", "x.unknown")));
            testCase.verifyEqual(string(response.error.code), "unsupported-file");
            response = api.handle(struct("id", 4, "method", "files.send", "params", struct("path", "project.nansen.json", "name", "not a name")));
            testCase.verifyEqual(string(response.error.code), "invalid-params");
        end

        function theCurrentFolderChangesAndFiguresClose(testCase)
            % dev's Change Current Folder, its file viewer's Make Current Folder, and Close All Figures
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            project = nansen.demo.create(fullfile(fixture.Folder, "demo"));
            api = nansen.Api(Project=project);
            before = pwd;
            testCase.addTeardown(@() cd(before));
            info = api.handle(struct("id", 1, "method", "app.info")).result;
            testCase.verifyTrue(info.changeFolder);
            result = api.handle(struct("id", 2, "method", "app.changeFolder", "params", struct("path", "tables"))).result;
            testCase.verifyTrue(endsWith(string(result.path), filesep + "tables"));
            testCase.verifyTrue(endsWith(string(pwd), filesep + "tables"));
            api.ChangeFolder = @(folder) assignin("base", "nansenApiTestFolder", string(folder));
            testCase.addTeardown(@() evalin("base", "clear nansenApiTestFolder"));
            result = api.handle(struct("id", 3, "method", "app.changeFolder")).result;
            testCase.verifyEqual(evalin("base", "nansenApiTestFolder"), string(result.path));
            testCase.verifyTrue(isfile(fullfile(result.path, "project.nansen.json")));
            response = api.handle(struct("id", 4, "method", "app.changeFolder", "params", struct("path", "project.nansen.json")));
            testCase.verifyEqual(string(response.error.code), "invalid-params");
            response = api.handle(struct("id", 5, "method", "app.changeFolder", "params", struct("path", "no/such")));
            testCase.verifyEqual(string(response.error.code), "file-not-found");

            closed = figure(Visible="off");
            kept = figure(Visible="off");
            testCase.addTeardown(@() delete(kept));
            testCase.verifyGreaterThanOrEqual(nansen.Api.closeAllFigures(kept), 1);   % the app keeps its own window
            testCase.verifyFalse(isvalid(closed));
            testCase.verifyTrue(isvalid(kept));
            api.CloseFigures = @() 3;
            result = api.handle(struct("id", 6, "method", "app.closeFigures")).result;
            testCase.verifyEqual(result.closed, 3);
        end

        function oneDatasetOfAnHdf5FileGoesToTheWorkspace(testCase)
            % dev's file viewer's NWB node Assign to Workspace
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            project = nansen.demo.create(fullfile(fixture.Folder, "demo"));
            file = fullfile(project.Folder, "recording.nwb");
            h5create(file, "/acquisition/series/data", [3 2], Datatype="int16");   % 2 x 3 in the file's order
            h5write(file, "/acquisition/series/data", int16([0 3; 1 4; 2 5]));
            api = nansen.Api(Project=project);
            api.SendToWorkspace = @(name, value) assignin("base", "nansenApiTestDataset", {name, value});
            testCase.addTeardown(@() evalin("base", "clear nansenApiTestDataset"));
            result = api.handle(struct("id", 1, "method", "files.send", "params", ...
                struct("path", "recording.nwb", "dataset", "/acquisition/series/data"))).result;
            testCase.verifyEqual(string(result.name), "data");
            testCase.verifyEqual(result.shape, {2, 3});
            testCase.verifyEqual(string(result.dataType), "int16");
            sent = evalin("base", "nansenApiTestDataset");
            testCase.verifyEqual(sent{2}, int16([0 3; 1 4; 2 5]));   % as h5read gives it
            response = api.handle(struct("id", 2, "method", "files.send", "params", struct("path", "recording.nwb", "dataset", "/acquisition")));
            testCase.verifyEqual(string(response.error.code), "invalid-params");
            response = api.handle(struct("id", 3, "method", "files.send", "params", struct("path", "project.nansen.json", "dataset", "/data")));
            testCase.verifyEqual(string(response.error.code), "unsupported-file");
        end

        function aFileMethodRunsOnAFile(testCase)
            % dev's project filemethods on the file viewer's menu: its example, Download File, fetches a placeholder
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            project = nansen.demo.create(fullfile(fixture.Folder, "demo"));
            case_ = fullfile(nansen.internal.repoRoot(), "conformance", "api", "files", "project");
            mkdir(fullfile(project.Folder, "methods"));
            mkdir(fullfile(project.Folder, "matlab"));
            copyfile(fullfile(case_, "methods", "lab.download_file.method.nansen.json"), fullfile(project.Folder, "methods"));
            copyfile(fullfile(case_, "matlab", "labDownloadFile.m"), fullfile(project.Folder, "matlab"));
            archive = fullfile(fixture.Folder, "archive");
            mkdir(fullfile(archive, "raw"));
            nansen.internal.writeText(fullfile(archive, "raw", "big.tif"), "frames");
            mkdir(fullfile(project.Folder, "raw"));
            nansen.internal.writeText(fullfile(project.Folder, "raw", "big.tif"), "");   % a placeholder
            api = nansen.Api(Project=project);
            result = api.handle(struct("id", 1, "method", "files.run", "params", struct("methodId", "lab.download_file", ...
                "path", "raw/big.tif", "options", struct("archive", archive)))).result;
            testCase.verifyTrue(result.result.downloaded);
            testCase.verifyEqual(result.result.bytes, 6);
            testCase.verifyEqual(string(fileread(fullfile(project.Folder, "raw", "big.tif"))), "frames");
            result = api.handle(struct("id", 2, "method", "files.run", "params", struct("methodId", "lab.download_file", "path", "raw/big.tif"))).result;
            testCase.verifyFalse(result.result.downloaded);
            response = api.handle(struct("id", 3, "method", "files.run", "params", struct("methodId", "core.file_stats", "path", "raw/big.tif")));
            testCase.verifyEqual(string(response.error.code), "wrong-entity-type");
        end

        function aMethodOnlyPythonHasRunsInAPythonWorker(testCase)
            % methods.run hands it to python -m nansen worker; a stand-in does to the task what outcome.json says
            testCase.assumeFalse(ispc, "the stand-in worker is a script with a shebang");
            [status, ~] = system("python3 --version");
            testCase.assumeEqual(status, 0, "python3 is needed for the stand-in worker");
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            fake = fullfile(fixture.Folder, "python");
            nansen.internal.writeText(fake, strjoin([
                "#!/usr/bin/env python3"
                "import glob, json, os, sys"
                "folder = sys.argv[sys.argv.index('worker') + 1]"
                "outcome = json.load(open(os.path.join(folder, 'outcome.json')))"
                "for path in glob.glob(os.path.join(folder, 'tasks', '*.task.nansen.json')):"
                "    task = json.load(open(path))"
                "    if outcome and task['status'] == 'queued' and task.get('language') == 'python':"
                "        task.update(outcome)"
                "        json.dump(task, open(path + '.tmp', 'w'))"
                "        os.replace(path + '.tmp', path)"
                ], newline) + newline);
            system(sprintf('chmod +x "%s"', fake));
            catalog = nansen.Catalog(fullfile(fixture.Folder, "catalog.json"));
            catalog.saveSettings(struct("workers", struct("python", fake)));
            project = nansen.demo.create(fullfile(fixture.Folder, "demo"));
            project.createMethod("only_python", Title="Only Python", EntityType="session", Languages="python");
            api = nansen.Api(Project=project, Catalog=catalog);
            rows = api.handle(struct("id", 1, "method", "entities.list", "params", struct("entityType", "session"))).result.rows;
            rows = nansen.internal.asCellOfStructs(rows);
            params = struct("methodId", "only_python", "entityType", "session", "keys", {{rows{1}.key}});
            outcome = @(text) nansen.internal.writeText(fullfile(project.Folder, "outcome.json"), text);

            outcome('{"status": "completed", "result": [{"frames": 3}]}');
            result = api.handle(struct("id", 2, "method", "methods.run", "params", params)).result;
            testCase.verifyEqual(string(result.language), "python");
            testCase.verifyEqual(result.results.frames, 3);
            outcome('{"status": "failed", "error": {"identifier": "ImportError", "message": "no suite2p"}}');
            response = api.handle(struct("id", 3, "method", "methods.run", "params", params));
            testCase.verifyEqual(string(response.error.code), "task-failed");
            testCase.verifySubstring(string(response.error.message), "no suite2p");
            outcome('{}');   % the worker never takes it
            params.startTimeout = 1;
            response = api.handle(struct("id", 4, "method", "methods.run", "params", params));
            testCase.verifyEqual(string(response.error.code), "task-failed");
            testCase.verifySubstring(string(response.error.message), "worker-python.log");
            tasks = api.handle(struct("id", 5, "method", "tasks.list")).result;
            testCase.verifyEqual(string(tasks{end}.status), "cancelled");
        end

        function settingsAreKeptInTheCatalog(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            catalog = nansen.Catalog(fullfile(fixture.Folder, "catalog.json"));
            api = nansen.Api(Catalog=catalog);
            settings = api.handle(struct("id", 1, "method", "settings.get")).result;
            testCase.verifyTrue(settings.queue.autoStart);
            testCase.verifyFalse(settings.queue.debug);   % dev's task debug mode, off
            settings = api.handle(struct("id", 2, "method", "settings.save", "params", ...
                struct("settings", struct("queue", struct("autoStart", false))))).result;
            testCase.verifyFalse(settings.queue.autoStart);
            testCase.verifyFalse(catalog.settings().queue.autoStart);
            response = api.handle(struct("id", 3, "method", "settings.save", "params", ...
                struct("settings", struct("queue", struct("autoStart", "yes")))));
            testCase.verifyEqual(string(response.error.code), "invalid-params");
            response = api.handle(struct("id", 4, "method", "settings.save", "params", struct("settings", struct("other", struct()))));
            testCase.verifyEqual(string(response.error.code), "invalid-params");
            testCase.verifyFalse(api.StartQueue);   % a plain Api never starts a worker; nansen.App sets it from the setting
            testCase.verifyEqual(string(settings.queue.worker), "thread");
            settings = api.handle(struct("id", 5, "method", "settings.save", "params", ...
                struct("settings", struct("queue", struct("worker", "process"))))).result;
            testCase.verifyEqual(string(settings.queue.worker), "process");
            response = api.handle(struct("id", 6, "method", "settings.save", "params", ...
                struct("settings", struct("queue", struct("worker", "fork")))));
            testCase.verifyEqual(string(response.error.code), "invalid-params");
        end

        function theWorkerSettingChoosesThePool(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            catalog = nansen.Catalog(fullfile(fixture.Folder, "catalog.json"));
            catalog.saveSettings(struct("queue", struct("worker", "process")));
            project = nansen.Project.create(fullfile(fixture.Folder, "p"), "P");
            api = nansen.Api(Catalog=catalog, Project=project);
            status = api.handle(struct("id", 1, "method", "queue.status")).result;
            testCase.verifyEqual(string(status.worker), "process");
            testCase.verifyEqual(string(status.executor), "matlab");
            if ~nansen.TaskQueue.hasProcessPools()
                response = api.handle(struct("id", 2, "method", "queue.start"));
                testCase.verifyEqual(string(response.error.code), "dependency-missing");
            end
            api.handle(struct("id", 3, "method", "settings.save", "params", struct("settings", struct("queue", struct("worker", "thread")))));
            status = api.handle(struct("id", 4, "method", "queue.status")).result;
            testCase.verifyEqual(string(status.worker), "thread");
        end

        function aSharedProjectIsInstalledFromGit(testCase)
            testCase.assumeEqual(system("git --version"), 0, "git is not installed");
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            shared = fullfile(fixture.Folder, "shared");
            nansen.Project.create(shared, "Shared");
            git = @(command) system(sprintf('git -C "%s" -c user.name=t -c user.email=t@t %s', shared, command));
            testCase.assertEqual(git("init -q") + git("add .") + git("commit -q -m project"), 0);
            api = nansen.Api(Catalog=nansen.Catalog(fullfile(fixture.Folder, "catalog.json")));
            call = @(params) api.handle(struct("id", 1, "method", "catalog.install", "params", params));
            response = call(struct("url", shared, "path", fullfile(fixture.Folder, "mine")));
            projects = response.result;
            if isstruct(projects)
                projects = num2cell(projects);
            end
            testCase.verifyEqual(string(cellfun(@(p) string(p.name), projects)), "Shared");
            testCase.verifyTrue(isfile(fullfile(fixture.Folder, "mine", "project.nansen.json")));
            response = call(struct("url", shared, "path", fullfile(fixture.Folder, "mine")));
            testCase.verifyEqual(string(response.error.code), "folder-not-empty");
            response = call(struct("url", fullfile(fixture.Folder, "nowhere"), "path", fullfile(fixture.Folder, "other")));
            testCase.verifyEqual(string(response.error.code), "install-failed");
        end

        function aMovedProjectIsLocatedAgain(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            api = nansen.Api(Catalog=nansen.Catalog(fullfile(fixture.Folder, "catalog.json")));
            call = @(method, params) api.handle(struct("id", 1, "method", method, "params", params));
            call("project.create", struct("path", fullfile(fixture.Folder, "pilot"), "name", "Pilot"));
            call("project.create", struct("path", fullfile(fixture.Folder, "other"), "name", "Other"));
            delete(api);
            api = nansen.Api(Catalog=nansen.Catalog(fullfile(fixture.Folder, "catalog.json")));
            call = @(method, params) api.handle(struct("id", 1, "method", method, "params", params));
            movefile(fullfile(fixture.Folder, "pilot"), fullfile(fixture.Folder, "moved"));
            projects = call("catalog.list", struct()).result;
            entry = projects{cellfun(@(p) string(p.name) == "Pilot", projects)};
            testCase.verifyFalse(entry.available);
            response = call("catalog.relocate", struct("path", entry.path, "newPath", fullfile(fixture.Folder, "other")));
            testCase.verifyEqual(string(response.error.code), "invalid-params");
            projects = call("catalog.relocate", struct("path", entry.path, "newPath", fullfile(fixture.Folder, "moved"))).result;
            moved = projects{cellfun(@(p) string(p.name) == "Pilot", projects)};
            testCase.verifyTrue(moved.available);
        end

        function catalogListsTheLastOpenedFirstWithinOneSecond(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            api = nansen.Api(Catalog=nansen.Catalog(fullfile(fixture.Folder, "catalog.json")));
            names = ["First", "Second", "Third"];   % often in one second, which lastOpened cannot tell apart
            for name = names
                api.handle(struct("id", 1, "method", "project.create", "params", ...
                    struct("path", fullfile(fixture.Folder, name), "name", name, "modules", {{'core'}})));
            end
            projects = api.handle(struct("id", 2, "method", "catalog.list")).result;
            testCase.verifyEqual(cellfun(@(p) string(p.name), projects), flip(names));
        end

        function appAnswersTheDashboard(testCase)
            % The page loads in the uihtml, calls setup, and its requests reach the API over the bridge.
            testCase.assumeTrue(usejava("desktop") || ispc || ismac || ~isempty(getenv("DISPLAY")), "no display");
            [rendered, probeLog] = uihtmlRenders();
            testCase.log(1, "uihtml probe (" + version("-release") + "): " + probeLog)
            testCase.assumeTrue(rendered, "a uihtml does not run its page in this MATLAB session: " + probeLog);
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            project = nansen.demo.create(fullfile(fixture.Folder, "demo"));
            app = nansen.App(Project=project, CatalogPath=fullfile(fixture.Folder, "catalog.json"), StartQueue=false);
            testCase.addTeardown(@() app.close());
            testCase.verifyClass(app.Html, "matlab.ui.control.HTML");
            expected = ["app.info", "project.info", "fragments.list", "methods.list", "queue.status"];
            started = tic;
            while toc(started) < 60 && ~all(ismember(expected, app.Requests))
                drawnow
                pause(0.25)
            end
            testCase.verifyTrue(all(ismember(expected, app.Requests)), ...
                "requests from the page: " + strjoin(app.Requests, ", ") + newline + ...
                "the page reported: " + strjoin(app.PageLog, newline));
            testCase.verifyFalse(any(startsWith(app.PageLog, ["error:", "unhandled:"])), strjoin(app.PageLog, newline));
        end
    end
end

function [rendered, log] = uihtmlRenders()
    % Whether a uihtml runs its page here at all: a minimal page that only calls sendEventToMATLAB and sets Data.
    % When even this page never answers, the app test has nothing to test in this session.
    fig = uifigure(Visible="on");
    cleanup = onCleanup(@() delete(fig));
    setappdata(fig, "probe", strings(1, 0))
    note = @(text) setappdata(fig, "probe", [getappdata(fig, "probe"), string(text)]);
    source = ['<html><body><script>function setup(h) {', ...
        ' h.Data = "data"; h.sendEventToMATLAB("event", "hello"); }</script></body></html>'];
    uihtml(fig, HTMLSource=source, ...
        HTMLEventReceivedFcn=@(~, event) note("event " + string(event.HTMLEventName)), ...
        DataChangedFcn=@(source, ~) note("data " + string(source.Data)));
    started = tic;
    while toc(started) < 30 && numel(getappdata(fig, "probe")) < 2
        drawnow
        pause(0.25)
    end
    received = getappdata(fig, "probe");
    rendered = any(startsWith(received, "event"));
    if isempty(received)
        received = "nothing";
    end
    log = sprintf("%s after %.1f s", strjoin(received, ", "), toc(started));
end
