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

        function sameMethodsAsPython(testCase)
            api = nansen.Api();
            info = jsondecode(char(api.handleJson('{"id": 1, "method": "app.info"}'))).result;
            expected = ["app.info", "catalog.list", "catalog.remove", "data.status", "dataVariables.list", ...
                "entities.add", "entities.get", "entities.list", "entities.remove", "entities.update", ...
                "fragments.list", "fragments.update", "methods.list", "methods.run", "pipelines.list", "pipelines.submit", "presets.delete", ...
                "presets.list", "presets.save", "project.create", "project.info", "project.open", "project.scan", ...
                "project.sync", "queue.start", "queue.status", "queue.stop", "tasks.cancel", "tasks.clear", ...
                "tasks.get", "tasks.list", "tasks.remove", "tasks.retry", "tasks.runNext", "tasks.submit"];
            testCase.verifyEqual(sort(string(info.methods))', expected);
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

        function appOpensWhenThereIsADisplay(testCase)
            testCase.assumeTrue(usejava("desktop") || ~isempty(getenv("DISPLAY")), "no display");
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            project = nansen.Project.create(fullfile(fixture.Folder, "p"), "Pilot");
            app = nansen.App(Project=project, CatalogPath=fullfile(fixture.Folder, "catalog.json"), ...
                Visible=false, StartQueue=false);
            testCase.addTeardown(@() app.close());
            testCase.verifyClass(app.Html, "matlab.ui.control.HTML");
        end
    end
end
