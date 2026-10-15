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

        function twoPhotonQuickstart(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            project = nansen.demo.createTwoPhoton(fullfile(fixture.Folder, "tutorial"));
            testCase.verifyEqual(project.Title, "Two-photon quickstart");
            testCase.verifyEqual(project.table("subject").numRows(), 2);
            rows = project.table("session").toJsonRows();
            testCase.verifyEqual(numel(rows), 4);
            testCase.verifyTrue(all(cellfun(@(r) isequal(r.frame_rate, 31.25) && isequal(r.pixel_size_um, 2), rows)));
            raw = dir(fullfile(fixture.Folder, "tutorial", "data", "raw", "sub-m1", "ses-s1", "rec.raw"));
            testCase.verifyEqual(raw.bytes, 64 * 64 * 300 * 2);
            entities = project.entities("session");
            stack = project.openStack(entities{1}, "TwoPhotonSeries_Original");
            testCase.verifyEqual(stack.Size, [64, 64, 300]);
            testCase.verifyEqual(stack.ClassName, "uint16");
        end

        function demoNeedsAnEmptyFolder(testCase)
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            nansen.internal.writeText(fullfile(fixture.Folder, "x.txt"), "");
            testCase.verifyError(@() nansen.demo.create(fixture.Folder), "nansen:FolderNotEmpty");
        end
    end
end
