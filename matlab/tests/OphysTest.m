classdef OphysTest < matlab.unittest.TestCase
%OphysTest The ophys module's numerics and file adapters, apart from the conformance case that runs them through the API

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
        function roundsHalfAwayFromZeroInTheScaledValue(testCase)
            testCase.verifyEqual(ophys.internal.roundTo(2.5, 0), 3);
            testCase.verifyEqual(ophys.internal.roundTo(0.12345, 4), 0.1235);
            testCase.verifyTrue(isnan(ophys.internal.roundTo(NaN, 2)));
        end

        function findsShiftsExactlyOnATexturedScene(testCase)
            rng(3);
            scene = randn(40, 44);
            scene = conv2(scene, ones(3), "same");
            truth = [0, 0; 2, -3; -4, 1; 5, 5; -1, -2];
            frames = zeros(40, 44, 5);
            for t = 1:5
                frames(:, :, t) = circshift(scene, truth(t, :));
            end
            reference = conj(fft2(scene)) .* ophys.internal.smoothing(40, 44);
            testCase.verifyEqual(ophys.internal.estimateShifts(frames, reference, 6), truth);
            testCase.verifyNotEqual(ophys.internal.estimateShifts(frames, reference, 4), truth);
        end

        function movesFramesBackAndFillsWithZero(testCase)
            stack = uint16(reshape(1:16, 4, 4)');
            out = ophys.internal.applyShifts(stack, [1, -1]);
            testCase.verifyClass(out, "uint16");
            testCase.verifyEqual(double(out), [0, 5, 6, 7; 0, 9, 10, 11; 0, 13, 14, 15; 0, 0, 0, 0]);
        end

        function componentsAreFourConnectedInRowMajorOrder(testCase)
            mask = logical([0, 0, 1, 1; 1, 0, 0, 1; 1, 1, 0, 0; 0, 0, 1, 0]);
            found = ophys.internal.components(mask);
            testCase.verifyEqual(found, {[1, 3; 1, 4; 2, 4], [2, 1; 3, 1; 3, 2], [4, 3]});
        end

        function dilatesBySquareDistance(testCase)
            mask = false(7);
            mask(4, 4) = true;
            testCase.verifyEqual(nnz(ophys.internal.dilate(mask, 2)), 25);
            union = mask;
            union(4, 6) = true;
            ring = ophys.internal.dilate(mask, 2) & ~ophys.internal.dilate(mask, 1) & ~union;
            testCase.verifyEqual(nnz(ring), 15);
        end

        function percentilesInterpolateAsNumpy(testCase)
            values = (1:10)';
            testCase.verifyEqual(ophys.internal.percentileOf(values, 20), 2.8, AbsTol=1e-12);
            testCase.verifyEqual(ophys.internal.percentileOf([values, 2 * values], 100), [10, 20]);
            moving = ophys.internal.movingPercentile((1:31)', 50, 5);
            testCase.verifyEqual(moving([1, 11, 31])', [2, 11, 30]);
            testCase.verifyTrue(isnan(ophys.internal.percentileOf([1; NaN; 3], 50)));
        end

        function anRoiOfOnePixelIsStillAList(testCase)
            document = struct("imageSize", [4, 5], "rois", {{ophys.internal.makeRoi(1, [3, 4])}});
            text = jsonencode(document);
            testCase.verifyTrue(contains(text, """pixels"":[[2,3]]"), text);
            testCase.verifyTrue(contains(text, """rois"":[{"), text);
            masks = ophys.internal.roiMasks(jsondecode(text), 4, 5);
            testCase.verifyEqual(numel(masks), 1);
            testCase.verifyTrue(masks{1}(3, 4));
            testCase.verifyEqual(nnz(masks{1}), 1);
            testCase.verifyError(@() ophys.internal.roiMasks(jsondecode(text), 5, 5), "nansen:InvalidData");
        end

        function sciscanRoundTrips(testCase)
            adapter = ophys.SciScanRaw();
            stack = uint16(reshape(0:59, 5, 3, 4));
            stack = permute(stack, [2, 1, 3]);   % 3 x 5 x 4, the values in row-major order
            path = fullfile(testCase.Folder, "rec.raw");
            adapter.write(path, stack);
            testCase.verifyTrue(contains(fileread(fullfile(testCase.Folder, "rec.ini")), "x.pixels = 5"));
            testCase.verifyEqual(adapter.read(path), stack);
            fid = fopen(path, "r", "ieee-be");
            first = fread(fid, 5, "uint16")';
            fclose(fid);
            testCase.verifyEqual(first, double(stack(1, :, 1)));   % x varies fastest, big-endian
            two = single(reshape(1:120, 3, 5, 2, 4));
            adapter.write(fullfile(testCase.Folder, "two.raw"), two);
            testCase.verifyEqual(adapter.read(fullfile(testCase.Folder, "two.raw")), two);
            testCase.verifyError(@() adapter.write(path, int32(stack)), "nansen:InvalidParams");
        end

        function readsTheRecordingsPythonWrote(testCase)
            folder = fullfile(nansen.internal.repoRoot(), "conformance", "api", "ophys", "project", "data", "raw", "sub-m1");
            raw = ophys.SciScanRaw().read(fullfile(folder, "ses-s1", "rec.raw"));
            testCase.verifyClass(raw, "uint16");
            testCase.verifyEqual(size(raw), [32, 32, 40]);
            testCase.verifyEqual(ophys.internal.roundTo(mean(double(raw), "all"), 4), 202.9881);
            tiff = ophys.TiffStack().read(fullfile(folder, "ses-s2", "rec.tif"));
            testCase.verifyEqual(size(tiff), [32, 32, 40]);
            testCase.verifyEqual(ophys.internal.roundTo(mean(double(tiff), "all"), 4), 201.0274);
        end

        function tiffRoundTrips(testCase)
            adapter = ophys.TiffStack();
            stack = uint16(reshape(1:60, 3, 4, 5));
            path = fullfile(testCase.Folder, "s.tif");
            adapter.write(path, stack);
            testCase.verifyEqual(adapter.read(path), stack);
            values = single(rand(6, 7, 2));
            adapter.write(path, values);
            testCase.verifyEqual(adapter.read(path), values);
            testCase.verifyError(@() adapter.write(path, int64(stack)), "nansen:InvalidParams");
        end

        function wrappersSayWhatIsMissing(testCase)
            if exist("normcorre", "file") ~= 2
                testCase.verifyError(@() ophys.normcorre(struct(), struct(), []), "nansen:DependencyMissing");
            end
            if ~exist("imviewer", "file")
                testCase.verifyError(@() ophys.openInImviewer(struct(), struct(), []), "nansen:DependencyMissing");
            end
        end
    end
end
