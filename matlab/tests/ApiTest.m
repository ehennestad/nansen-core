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

        function appAnswersTheDashboard(testCase)
            % The page loads in the uihtml, calls setup, and its requests reach the API over the bridge.
            testCase.assumeTrue(usejava("desktop") || ispc || ismac || ~isempty(getenv("DISPLAY")), "no display");
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
                "requests from the page: " + strjoin(app.Requests, ", "));
        end
    end
end
