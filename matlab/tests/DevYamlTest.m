classdef DevYamlTest < matlab.unittest.TestCase
%DevYamlTest NANSEN dev's metadata files: the YAML reader (nansen.internal.parseDevYaml), and a stack's metadata taken
%from them when its own files say nothing. Python's test_devyaml.py checks the same; conformance/yaml and
%conformance/api/dev-metadata hold both.

    properties
        Folder string
    end

    methods (TestMethodSetup)
        function setUp(testCase)
            testCase.applyFixture(matlab.unittest.fixtures.PathFixture( ...
                fullfile(nansen.internal.repoRoot(), "modules", "ophys", "matlab")));
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            testCase.Folder = fixture.Folder;
        end
    end

    methods (Test)
        function numbersAndSpecialValues(testCase)
            value = nansen.internal.parseDevYaml("a: .nan" + newline + "b: -.Inf" + newline + "c: 1.0E-5" + newline + ...
                "d: 007" + newline + "e: '1'" + newline + "f: 1e3" + newline);
            testCase.verifyTrue(isnan(value.a));
            testCase.verifyEqual(value.b, -Inf);
            testCase.verifyEqual(value.c, 1e-5);
            testCase.verifyEqual(value.d, 7);
            testCase.verifyEqual(value.e, '1');
            testCase.verifyEqual(value.f, 1000);
        end

        function lineEndsByteOrderMarkAndEscapes(testCase)
            text = [char(65279), 'a: "x\x41"', char([13, 10]), 'b: [1,', char([13, 10]), '  2]', char([13, 10])];
            value = nansen.internal.parseDevYaml(text);
            testCase.verifyEqual(value.a, 'xA');
            testCase.verifyEqual(value.b, {1, 2});
        end

        function keysThatAreNotMatlabNamesAreLeftOut(testCase)
            value = nansen.internal.parseDevYaml("end: 1" + newline + "ok_2: 2" + newline + "_x: 3" + newline + ...
                string(repmat('k', 1, 64)) + ": 4" + newline);
            testCase.verifyEqual(value, struct("ok_2", 2));
        end

        function whatIsNotRead(testCase)
            for text = ["a: *x", "a: !!float 1", "{a: 1", "a: ""\q""", "a: |x" + newline + "  y", ...
                    "a:" + newline + "  - 1" + newline + " - 2"]
                testCase.verifyError(@() nansen.internal.parseDevYaml(text + newline), "nansen:InvalidData", text);
            end
        end

        function aStackMetadataFileGivesFrameRatePixelSizeAndPlaneStep(testCase)
            document = nansen.internal.parseDevYaml(strjoin(["TimeIncrement: 0.04", "TimeIncrementUnit: second", ...
                "PhysicalSizeX: 1.5", "PhysicalSizeY: 1.5", "PhysicalSizeXUnit: um", "PhysicalSizeYUnit: micron", ...
                "PhysicalSizeZ: 2.0", "PhysicalSizeZUnit: pixel"], newline));
            testCase.verifyEqual(nansen.internal.devStackMetadata(document), struct("frameRate", 25, "pixelSize", [1.5, 1.5]));
            % an adapter's (setMetadata): in its groups; dev's defaults (unit pixel, N/A) say nothing
            document = struct("Data", struct("SampleRate", 30.9), ...
                "Custom", struct("PhysicalSizeX", 1, "PhysicalSizeXUnit", 'um'), "TimeIncrement", 1, "TimeIncrementUnit", 'N/A');
            testCase.verifyEqual(nansen.internal.devStackMetadata(document), struct("frameRate", 30.9));
            document = struct("TimeIncrement", 250, "TimeIncrementUnit", 'microseconds', "SampleRate", 2, ...
                "PhysicalSizeX", 300, "PhysicalSizeY", 300, "PhysicalSizeXUnit", 'nanometre', "PhysicalSizeYUnit", 'NM', ...
                "PhysicalSizeZ", 0.0025, "PhysicalSizeZUnit", 'mm');
            testCase.verifyEqual(nansen.internal.devStackMetadata(document), ...
                struct("frameRate", 4000, "pixelSize", [0.3, 0.3], "zStep", 2.5));
            testCase.verifyEqual(nansen.internal.devStackMetadata(struct("TimeIncrement", 0, ...
                "TimeIncrementUnit", 'second', "SampleRate", true)), struct());
        end

        function theMetadataFileBesideADataFile(testCase)
            data = fullfile(testCase.Folder, "rec.tif");
            testCase.verifyEqual(nansen.internal.devStackMetadata(data), struct());
            nansen.internal.writeText(fullfile(testCase.Folder, "rec.yaml.txt"), "SampleRate: 2" + newline);   % SaveYamlAsTxt
            testCase.verifyEqual(nansen.internal.devStackMetadata(data), struct("frameRate", 2));
            nansen.internal.writeText(fullfile(testCase.Folder, "rec.yaml"), "SampleRate: 3" + newline);   % read first
            testCase.verifyEqual(nansen.internal.devStackMetadata(data), struct("frameRate", 3));
            nansen.internal.writeText(fullfile(testCase.Folder, "rec.yaml"), "SampleRate: [3" + newline);   % not read
            testCase.verifyEqual(nansen.internal.devStackMetadata(data), struct());
        end

        function aRecordingTakesWhatItsFilesDoNotSayFromDevsMetadataFile(testCase)
            folder = fullfile(testCase.Folder, "project");
            copyfile(fullfile(nansen.internal.repoRoot(), "conformance", "api", "ophys", "project"), folder);
            project = nansen.Project.open(folder);
            project.scan();
            project.sync("subject");
            project.sync("session");
            project.runTool("ophys.setup_variables", Options=struct("rawFilePattern", "tiff", "rawFileAdapter", "ophys.tiff_stack"));
            key = struct("subject_id", "m1", "session_id", "s2");
            entity = project.entity("session", key);
            stack = project.openStack(entity, "TwoPhotonSeries_Original");
            testCase.verifyEqual(stack.Metadata, struct());
            % beside the first file of the recording, in natural order (rec_part2.tif, then rec_part10.tif)
            raw = fullfile(folder, "data", "raw", "sub-m1", "ses-s2");
            nansen.internal.writeText(fullfile(raw, "rec_part2.yaml"), strjoin(["TimeIncrement: 0.0625", ...
                "TimeIncrementUnit: second", "PhysicalSizeX: 2.0", "PhysicalSizeY: 2.0", "PhysicalSizeXUnit: micrometer", ...
                "PhysicalSizeYUnit: micrometer"], newline) + newline);
            nansen.internal.writeText(fullfile(raw, "rec_part10.yaml"), "TimeIncrement: 1.0" + newline + "TimeIncrementUnit: second" + newline);
            stack = project.openStack(entity, "TwoPhotonSeries_Original");
            metadata = stack.Metadata;
            testCase.verifyEqual(metadata, struct("frameRate", 16, "pixelSize", [2, 2]));
            testCase.verifyEqual(project.sidecarMetadata(entity, "TwoPhotonSeries_Original"), metadata);
            % the entity's columns over dev's file (the viewer's stack properties, as dev's Edit Stack Properties wrote it)
            project.updateValues(entity, struct("frame_rate", 10, "z_step_um", 3));
            api = nansen.Api();
            api.handleJson(jsonencode(struct("id", 1, "method", "project.open", "params", struct("path", folder))));
            request = struct("id", 2, "method", "data.frame", "params", struct("entityType", "session", "key", key, ...
                "variable", "TwoPhotonSeries_Original"));
            response = jsondecode(char(api.handleJson(jsonencode(request))));
            testCase.verifyEqual(response.result.metadata, struct("frameRate", 10, "pixelSize", [2; 2], "zStep", 3));
        end
    end
end
