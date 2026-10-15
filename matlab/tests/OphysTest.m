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

        function devNeuropilGrowsAroundTheRoiOutsideEveryRoi(testCase)
            % two 2 x 2 ROIs that share a pixel; neuropil twice their area, one pixel apart from every ROI (as test_ophys.py)
            a = false(9, 9);
            a(3:4, 3:4) = true;
            b = false(9, 9);
            b(4:5, 4:5) = true;
            out = ophys.internal.expansionNeuropil({a, b}, a | b, 2, 1);
            testCase.verifyEqual(OphysTest.pixelsOf(out{1}), [0 1; 0 2; 0 3; 0 4; 1 0; 1 5; 2 0; 3 0; 4 0; 5 1]);
            testCase.verifyEqual(OphysTest.pixelsOf(out{2}), [1 5; 2 6; 3 6; 4 6; 5 1; 5 6; 6 2; 6 3; 6 4; 6 5]);
            out = ophys.internal.expansionNeuropil({a, b}, a | b, 2, 0);
            testCase.verifyEqual(nnz(out{1}), 22);
            testCase.verifyFalse(any(out{1} & (a | b), "all"));
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
            parts = fullfile(folder, "ses-s2", ["rec_part10.tif", "rec_part2.tif"]);
            tiff = all(ophys.TiffStack().open(parts));   % one recording, joined in natural order
            testCase.verifyEqual(size(tiff), [32, 32, 40]);
            testCase.verifyEqual(tiff(:, :, 1:15), ophys.TiffStack().read(parts(2)));
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

        function tiffIsWrittenAChunkAtATime(testCase)
            stack = int16(reshape(0:59, 3, 4, 5));
            path = fullfile(testCase.Folder, "c.tif");
            writer = ophys.TiffStack().create(path, size(stack), "int16");
            writer.write(1, stack(:, :, 1:2));
            writer.write(3, stack(:, :, 3));
            testCase.verifyError(@() writer.write(5, stack(:, :, 5)), "nansen:InvalidParams");   % frame 4 was skipped
            writer.write(4, stack(:, :, 4:5));
            writer.close();
            testCase.verifyEqual(ophys.TiffStack().read(path), stack);
        end

        function oasisGivesWhatPythonGives(testCase)
            [c, s] = ophys.internal.oasisAr1([0, 1, 0.5, 0.2, 2, 1, 0.4, -0.3], 0.8, 0.1);
            testCase.verifyEqual(c', [0, 0.721701795472, 0.577361436378, 0.461889149102, 1.212244954459, ...
                0.969795963567, 0.775836770854, 0.620669416683], AbsTol=1e-11);
            testCase.verifyEqual(s', [0, 0.7217017954723, 0, 0, 0.8427336351768, 0, 0, 0], AbsTol=1e-11);
            testCase.verifyEqual(ophys.internal.noiseLevel([1; 2; 4]), 1.5 / (0.6745 * sqrt(2)), AbsTol=1e-15);
            testCase.verifyTrue(isnan(ophys.internal.noiseLevel([1; NaN; 4])));
        end

        function smoothingKeepsAConstant(testCase)
            flat = 7 * ones(4, 5, 6);
            testCase.verifyEqual(ophys.internal.gaussianAlong(flat, 3, 1.5), flat, AbsTol=1e-12);
            testCase.verifyEqual(ophys.internal.gaussianAlong(flat, 1, 2), flat, AbsTol=1e-12);
        end

        function readsScanImageChannelsPlanesAndRois(testCase)
            text = "SI.hChannels.channelSave = [1;2]" + newline + "scanimage.SI.hStackManager.numSlices = 3" + newline + "SI.hRoiManager.mroiEnable = true";
            testCase.verifyEqual(ophys.ScanImageTiff.siNumbers(text, "hChannels.channelSave"), [1, 2]);
            testCase.verifyEqual(ophys.ScanImageTiff.siNumbers(text, "hStackManager.numSlices"), 3);
            testCase.verifyEqual(ophys.ScanImageTiff.siNumbers(text, "hRoiManager.mroiEnable"), 1);
            testCase.verifyEmpty(ophys.ScanImageTiff.siNumbers(text, "hFastZ.enable"));
            folder = fullfile(nansen.internal.repoRoot(), "conformance", "api", "ophys", "project", "data", "raw", "sub-m1");
            files = fullfile(folder, "ses-s4", ["rec_00002.tif", "rec_00001.tif"]);
            stack = ophys.ScanImageTiff().open(files);   % joined in natural order, whatever order they come in
            data = stack.all();
            testCase.verifyEqual(size(data), [16, 64, 2, 2, 3]);
            testCase.verifyFalse(any(data == 9999, "all"));   % no flyback lines
            first = ophys.ScanImageTiff().read(files(2));   % 7 pages: one whole volume of 2 channels x 2 planes
            testCase.verifyEqual(size(first, 1:5), [16, 64, 2, 2, 1]);
            testCase.verifyEqual(first, data(:, :, :, :, 1));
            testCase.verifyEqual(stack.frames(2, 2), data(:, :, :, :, 2));   % begins in one file and ends in the next
            % the volume rate, actualStackZStepSize over stackZStepSize, and the pixel size of the first ROI's scanfield
            testCase.verifyEqual(stack.Metadata, struct("frameRate", 7.5, "pixelSize", [1.5, 1.5], "zStep", 4));
            testCase.verifyError(@() ophys.ScanImageTiff().read(fullfile(folder, "ses-s2", "rec_part2.tif")), "nansen:InvalidData");
        end

        function editsRoisWithPlacesOnTheirPlane(testCase)
            document = jsondecode(['{"imageSize": [10, 10], "rois": [{"id": 1, "pixels": [[1, 1]], "plane": 1, "channel": 1}, ' ...
                '{"id": 2, "pixels": [[2, 2]], "plane": 2, "channel": 1}, {"id": 3, "pixels": [[3, 3]], "plane": 2, "channel": 1}]}']);
            here = nansen.internal.roisAt(document, 2, 1);
            testCase.verifyEqual(cellfun(@(r) r.id, here.rois), [2, 3]);
            testCase.verifyEmpty(nansen.internal.roisAt(document, 1, 2).rois);
            plain = jsondecode('{"imageSize": [10, 10], "rois": [{"id": 1, "pixels": [[1, 1]]}]}');
            testCase.verifyEqual(nansen.internal.roisAt(plain, 3, 2), plain);   % no places: all of them, on any plane
            [changed, added] = nansen.internal.updateRoisAt(document, 2, 1, struct("id", 1, "classification", "accepted"), [], ...
                struct("pixels", [5, 5]), [], [], [], missing);
            testCase.verifyEqual(added, {4});
            testCase.verifyEqual(cellfun(@(r) r.id, changed.rois), [1, 2, 3, 4]);
            testCase.verifyEqual(cellfun(@(r) r.plane, changed.rois), [1, 2, 2, 2]);
            testCase.verifyEqual(changed.rois{1}.classification, 'accepted');
            % undo on plane 2 restores plane 2's ROIs only; plane 1's stay
            restored = nansen.internal.updateRoisAt(changed, 2, 1, [], [], [], [], [], [], {struct("id", 2, "pixels", [2, 2])});
            testCase.verifyEqual(cellfun(@(r) r.id, restored.rois), [1, 2]);
            testCase.verifyEqual(cellfun(@(r) r.plane, restored.rois), [1, 2]);
            testCase.verifyEqual(cellfun(@(r) r.channel, restored.rois), [1, 1]);
            testCase.verifyEqual(restored.rois{1}.classification, 'accepted');
        end

        function updatesRois(testCase)
            document = jsondecode('{"imageSize": [10, 10], "rois": [{"id": 1, "pixels": [[1, 1]]}, {"id": 5, "pixels": [[2, 2], [2, 3]]}]}');
            [changed, added] = nansen.internal.updateRois(document, struct("id", 5, "classification", "rejected"), 1, ...
                struct("pixels", [3, 3; 3, 4; 11, 0]));
            testCase.verifyEqual(added, {6});
            testCase.verifyEqual(cellfun(@(r) r.id, changed.rois), [5, 6]);
            testCase.verifyEqual(changed.rois{1}.classification, 'rejected');
            testCase.verifyEqual(changed.rois{2}.center, [3, 3.5]);
            text = jsonencode(changed);
            testCase.verifyTrue(contains(text, """pixels"":[[3,3],[3,4]]"), text);
            testCase.verifyError(@() nansen.internal.updateRois(document, [], 7, []), "nansen:InvalidParams");
            testCase.verifyError(@() nansen.internal.updateRois(document, struct("id", 1, "classification", "maybe"), [], []), "nansen:InvalidParams");
            testCase.verifyError(@() nansen.internal.updateRois(document, [], [], struct("pixels", [20, 20])), "nansen:InvalidParams");
        end

        function findsTheRegionOfAFov(testCase)
            atlas = jsondecode(nansen.internal.readText(fullfile(nansen.internal.repoRoot(), "modules", "ophys", "atlas", "dorsal_cortex.json")));
            testCase.verifyEqual(ophys.internal.atlasRegion(atlas, 2.3, -3.6), 'V1');
            testCase.verifyEqual(ophys.internal.atlasRegion(atlas, 1, 1), 'M2');
            testCase.verifyEmpty(ophys.internal.atlasRegion(atlas, 9, 9));
        end

        function morphologyForQuicky(testCase)
            ring = false(7);
            ring(2:6, 2:6) = true;
            ring(3:5, 3:5) = false;
            ring(4, 4) = true;
            testCase.verifyEqual(nnz(ophys.internal.fillHoles(ring)), 25);
            touching = false(6);
            touching(1:2, 1:2) = true;
            touching(4:5, 4:5) = true;
            testCase.verifyEqual(nnz(ophys.internal.clearBorder(touching)), 4);
            dot = false(9);
            dot(5, 5) = true;
            grown = ophys.internal.dilateBy(dot, ophys.internal.diskOffsets(2));
            testCase.verifyEqual(nnz(grown), 13);
            testCase.verifyEqual(ophys.internal.erodeBy(grown, ophys.internal.diskOffsets(2)), dot);
            testCase.verifyTrue(all(ophys.internal.erodeBy(true(5), ophys.internal.diskOffsets(1)), "all"));
            stack = reshape(0:27, 7, 2, 2);
            stack = permute(stack, [3, 2, 1]);   % 2 x 2 x 7, as numpy's arange(28).reshape(2, 2, 7)
            binned = ophys.internal.binMax(stack, 3);
            testCase.verifyEqual(squeeze(binned(1, 1, :))', [2, 5]);
            testCase.verifyEqual(squeeze(ophys.internal.movingMean(reshape(0:5, 1, 1, 6), 4))', [0.5, 1, 1.5, 2.5, 3.5, 4], AbsTol=1e-12);
        end

        function wrappersSayWhatIsMissing(testCase)
            if exist("normcorre", "file") ~= 2
                testCase.verifyError(@() ophys.normcorre(struct(), struct(), []), "nansen:DependencyMissing");
            end
            for name = ["extract", "flowreg", "caimanDeconvolution", "flufinder", "cnmf"]
                testCase.verifyError(@() feval("ophys." + name, struct(), struct(), []), "nansen:DependencyMissing", name);
            end
            if ~exist("imviewer", "file")
                testCase.verifyError(@() ophys.openInImviewer(struct(), struct(), []), "nansen:DependencyMissing");
            end
            if exist("NwbFile", "class") ~= 8
                testCase.verifyError(@() ophys.exportNwb(struct(), struct(), []), "nansen:DependencyMissing");
            end
        end
    end

    methods (Static)
        function pixels = pixelsOf(mask)
            % [row, column] (0-based) of a mask's pixels, in row-major order as NumPy lists them
            [rows, columns] = find(mask);
            pixels = sortrows([rows, columns] - 1);
        end
    end
end
