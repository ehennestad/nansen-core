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
