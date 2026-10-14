classdef DemoTest < matlab.unittest.TestCase
%DemoTest The demo project builds, scans and has its tables filled

    methods (Test)
        function demoProject(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            project = nansen.demo.create(fullfile(fixture.Folder, "demo"));
            testCase.verifyEqual(project.Title, "Two-photon demo");
            testCase.verifyEqual(project.EntityTypes, ["subject", "session"]);
            testCase.verifyEqual(project.table("subject").numRows(), 4);
            sessions = project.table("session");
            testCase.verifyEqual(sessions.numRows(), 14);
            rows = sessions.toJsonRows();
            testCase.verifyTrue(all(cellfun(@(r) ~isempty(r.n_files) && r.n_files >= 1, rows)));
            entities = project.entities("session");
            testCase.verifyTrue(all(cellfun(@(e) ~isempty(e.Record) && ~isempty(e.Row), entities)));
            testCase.verifyEqual(string(cellfun(@(p) p.name, project.presets("core.wait"), UniformOutput=false)), ["default", "quick"]);
        end

        function demoNeedsAnEmptyFolder(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            nansen.internal.writeText(fullfile(fixture.Folder, "x.txt"), "");
            testCase.verifyError(@() nansen.demo.create(fixture.Folder), "nansen:FolderNotEmpty");
        end
    end
end
