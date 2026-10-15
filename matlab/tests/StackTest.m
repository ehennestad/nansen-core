classdef StackTest < matlab.unittest.TestCase
%StackTest Stacks read a chunk of frames at a time (nansen.Stack), recordings kept in several files, and the
%ophys methods that read a recording in chunks and never whole. Python's test_stacks.py checks the same.

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
        function readsOnlyTheFramesAskedFor(testCase)
            data = reshape(0:119, 3, 4, 10);
            stack = nansen.Stack.fromArray(data);
            testCase.verifyEqual(size(stack), [3, 4, 10]);
            testCase.verifyEqual(stack.numFrames(), 10);
            [h, w, n] = size(stack);
            testCase.verifyEqual([h, w, n], [3, 4, 10]);
            testCase.verifyEqual(stack.frames(3, 5), data(:, :, 3:5));
            testCase.verifyEqual(size(stack.frames(9, 50)), [3, 4, 2]);   % cut to the stack
            testCase.verifyEqual(all(stack.select(2, 3)), reshape(data(:, 3, :), 3, 10));
            stack.MaxFrames = 4;
            testCase.verifyError(@() stack.all(), "nansen:InvalidParams");   % more than the limit allows
            testCase.verifyEqual(size(stack.frames(1, 4)), [3, 4, 4]);
        end

        function joinsStacksAlongTheFrames(testCase)
            joined = nansen.Stack.join({zeros(2, 2, 3), ones(2, 2, 4)});
            testCase.verifyEqual(size(joined), [2, 2, 7]);
            part = joined.frames(3, 5);
            testCase.verifyEqual(reshape(part(1, 1, :), 1, []), [0, 1, 1]);
            testCase.verifyError(@() nansen.Stack.join({zeros(2, 2, 3), ones(2, 3, 1)}), "nansen:InvalidData");
            testCase.verifyEqual(nansen.internal.naturalOrder(["f_10.tif", "f_2.tif", "f_1.tif"]), ["f_1.tif", "f_2.tif", "f_10.tif"]);
        end

        function npyFilesAreReadAndWrittenAChunkAtATime(testCase)
            rng(0);
            data = uint16(randi([0, 999], 5, 6, 30));
            adapter = nansen.adapters.Npy();
            out = fullfile(testCase.Folder, "out.npy");
            writer = adapter.create(out, size(data), "uint16");
            for start = 1:7:30
                writer.write(start, data(:, :, start:min(start + 6, 30)));
            end
            writer.close();
            testCase.verifyEqual(adapter.read(out), data);
            [~, ~, ~, fortran] = nansen.adapters.Npy.header(out);
            testCase.verifyTrue(fortran);   % frames kept together
            more = fullfile(testCase.Folder, "more.npy");
            adapter.write(more, data + 1);   % C order: read a run of values for each pixel
            stack = adapter.open([out, more]);   % natural order: more.npy, then out.npy
            testCase.verifyEqual(size(stack), [5, 6, 60]);
            testCase.verifyEqual(stack.frames(29, 32), cat(3, data(:, :, 29:30) + 1, data(:, :, 1:2)));
            gaps = adapter.create(fullfile(testCase.Folder, "gaps.npy"), [2, 2, 5], "single");
            gaps.write(4, ones(2, 2, 1, "single"));   % frames never written are 0
            gaps.close();
            testCase.verifyEqual(squeeze(sum(adapter.read(fullfile(testCase.Folder, "gaps.npy")), [1, 2]))', single([0, 0, 0, 4, 0]));
        end

        function filesOfOneRecordingMustAgree(testCase)
            ophys.TiffStack().write(fullfile(testCase.Folder, "a_1.tif"), zeros(8, 8, 2, "uint16"));
            ophys.TiffStack().write(fullfile(testCase.Folder, "a_2.tif"), zeros(6, 8, 2, "uint16"));
            testCase.verifyError(@() ophys.TiffStack().open(fullfile(testCase.Folder, ["a_1.tif", "a_2.tif"])), "nansen:InvalidData");
        end

        function aRecordingInSeveralFilesIsOneVariable(testCase)
            project = testCase.ophysProject();
            entity = project.entity("session", struct("subject_id", "m1", "session_id", "s2"));
            folder = fullfile(project.Folder, "data", "raw", "sub-m1", "ses-s2");
            whole = cat(3, ophys.TiffStack().read(fullfile(folder, "rec_part2.tif")), ophys.TiffStack().read(fullfile(folder, "rec_part10.tif")));
            testCase.verifyEqual(size(whole), [32, 32, 40]);
            testCase.verifyEqual(project.load(entity, "TwoPhotonSeries_Original", Cached=false), whole);
            stack = project.openStack(entity, "TwoPhotonSeries_Original");
            testCase.verifyEqual(stack.frames(14, 17), whole(:, :, 14:17));   % across the two files
            writer = project.stackWriter(entity, "", [4, 5, 6], "single");   % no variable: nothing written
            writer.write(1, zeros(4, 5, 6, "single"));
            writer.close();
        end

        function theLargeDataMethodsReadARecordingInChunks(testCase)
            project = testCase.ophysProject();
            key = struct("subject_id", "m1", "session_id", "s2");
            stack = testCase.longRecording(project);
            entity = project.entity("session", key);
            unlimited = project.run("ophys.image_stats", {entity}, Options=struct("stack", "TwoPhotonSeries_Original"));
            project.StackFrameLimit = 100;   % a method that read the recording whole would fail now
            testCase.verifyError(@() all(project.openStack(entity, "TwoPhotonSeries_Original")), "nansen:InvalidParams");
            limited = project.run("ophys.image_stats", {entity}, Options=struct("stack", "TwoPhotonSeries_Original"));
            testCase.verifyEqual(limited, unlimited);
            testCase.verifyEqual(limited{1}.n_frames, 250);
            testCase.verifyEqual(limited{1}.mean_intensity, ophys.internal.roundTo(mean(double(stack), "all"), 4));
            moved = project.run("ophys.motion_correction", {entity}, Options=struct("referenceFrames", 50));
            testCase.verifyEqual(moved{1}.frames, 250);
            corrected = project.openStack(entity, "TwoPhotonSeries_Corrected");
            testCase.verifyEqual(size(corrected), [48, 48, 250]);
            testCase.verifyEqual(corrected.ClassName, "uint16");
            [rows, columns] = ndgrid(11:13, 11:13);
            roi = struct("id", 1, "pixels", {num2cell([rows(:), columns(:)], 2)'});
            project.save(entity, "RoiArray", struct("imageSize", [48, 48], "rois", {{roi}}));
            signals = project.run("ophys.extract_signals", {entity});
            testCase.verifyEqual([signals{1}.frames, signals{1}.rois], [250, 1]);
            binned = project.run("ophys.downsample", {entity}, Options=struct("temporalFactor", 5, "spatialFactor", 2));
            testCase.verifyEqual(binned{1}.frames, 50);
            frame = nansen.internal.imageFrame(project.openStack(entity, "TwoPhotonSeries_Corrected"), 0, 0, "mean", []);
            testCase.verifyEqual(frame.frames, 250);
            image = nansen.internal.imageFrame(project.openStack(entity, "FovAverageProjection"), 0, 0, "", []);
            testCase.verifyEqual([image.height, image.width, image.frames], [48, 48, 1]);   % an image: its columns are not frames
            testCase.verifyError(@() project.run("ophys.detect_rois", {entity}), "nansen:InvalidParams");   % needs every frame at once
            project.StackFrameLimit = Inf;
            whole = project.load(entity, "TwoPhotonSeries_Corrected", Cached=false);
            testCase.verifyEqual(all(project.openStack(entity, "TwoPhotonSeries_Corrected")), whole);
        end
    end

    methods (Access = private)
        function project = ophysProject(testCase)
            %ophysProject The ophys conformance project, its raw recording read as TwoPhotonSeries_Original
            folder = fullfile(testCase.Folder, "project");
            copyfile(fullfile(nansen.internal.repoRoot(), "conformance", "api", "ophys", "project"), folder);
            project = nansen.Project.open(folder);
            project.scan();
            project.sync("subject");
            project.sync("session");
            project.runTool("ophys.setup_variables", Options=struct("rawFilePattern", "tiff", "rawFileAdapter", "ophys.tiff_stack"));
        end

        function stack = longRecording(~, project)
            %longRecording Session s2's recording replaced by a longer one, in three files, with a few cells and known shifts
            rng(7);
            frames = 250;
            scene = 300 + 40 * randn(48, 48);
            stack = repmat(scene, 1, 1, frames);
            [xx, yy] = meshgrid(1:48, 1:48);
            for center = [12, 12; 30, 20; 20, 36]'
                mask = (yy - center(1)) .^ 2 + (xx - center(2)) .^ 2 <= 9;
                stack = stack + mask .* reshape(200 * (rand(1, frames) < 0.1), 1, 1, []);
            end
            shifts = randi([-2, 2], frames, 2);
            for t = 1:frames
                stack(:, :, t) = circshift(stack(:, :, t), shifts(t, :));
            end
            stack = uint16(max(0, stack + 5 * randn(size(stack))));
            folder = fullfile(project.Folder, "data", "raw", "sub-m1", "ses-s2");
            delete(fullfile(folder, "*.tif"));
            bounds = [0, 90, 170, frames];
            for n = 1:3
                ophys.TiffStack().write(fullfile(folder, "rec_" + n + ".tif"), stack(:, :, bounds(n) + 1:bounds(n + 1)));
            end
            project.scan();
        end
    end
end
