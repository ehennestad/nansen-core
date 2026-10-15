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

        function presetsAreOptionsOfTheirMethods(testCase)
            % dev's shipped presets (Quicky's Soma, Soma (Virus) and Axons, NoRMCorre's Nonrigid (4x4) and Rigid), and
            % the module's own: each names options its method has, with values its schema takes (as test_ophys.py)
            module = nansen.Module.read(fullfile(nansen.internal.repoRoot(), "modules", "ophys"));
            found = module.entityMethods();
            ids = [found.Id];
            names = strings(1, 0);
            for document = module.presetDocuments()
                preset = document{1};
                method = found(ids == string(preset.method.id));
                testCase.assertNumElements(method, 1, preset.name);
                names(end + 1) = string(preset.method.id) + "/" + string(preset.name); %#ok<AGROW>
                testCase.verifyNotEqual(string(preset.name), "default");
                testCase.verifyEqual(string(preset.method.version), method.Version, preset.name);
                options = method.resolveOptions(preset.values);
                for field = reshape(string(fieldnames(preset.values)), 1, [])
                    testCase.verifyEqual(options.(field), preset.values.(field), string(preset.name) + "." + field);
                end
            end
            testCase.verifyTrue(all(ismember(["ophys.quicky/soma", "ophys.quicky/soma_virus", "ophys.quicky/axon", ...
                "ophys.normcorre/nonrigid", "ophys.normcorre/rigid"], names)));
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

        function roisCarryCellTypesLinksAndTheirIdentity(testCase)
            document = jsondecode(['{"imageSize": [10, 10], "rois": [{"id": 1, "pixels": [[1, 1]], "uid": "a-1", "tags": ["bright"]}, ' ...
                '{"id": 2, "pixels": [[2, 2]]}, {"id": 3, "pixels": [[3, 3]]}]}']);
            changed = nansen.internal.updateRois(document, [], [], [], [], [], [], missing, struct("id", 1, "cellType", "inhibitory"), {[1, 2, 3]});
            changed = jsondecode(jsonencode(changed));   % as the file has it
            testCase.verifyEqual(changed.rois{1}.links', [2, 3]);
            testCase.verifyEqual(changed.rois{2}.links, 1);
            outlines = nansen.internal.roiOutlines(changed);
            testCase.verifyEqual(string(outlines{1}.cellType), "inhibitory");
            gone = jsondecode(jsonencode(nansen.internal.updateRois(changed, [], 3, [])));   % a removed ROI leaves the links
            testCase.verifyEqual(gone.rois{1}.links, 2);
            restored = nansen.internal.updateRois(gone, [], [], [], [], [], [], {struct("id", 1, "pixels", [1, 1]), struct("id", 2, "pixels", [2, 2])});
            testCase.verifyEqual(string(restored.rois{1}.uid), "a-1");
            testCase.verifyEqual(string(restored.rois{1}.cellType), "inhibitory");
            testCase.verifyError(@() nansen.internal.updateRois(document, [], [], [], [], [], [], missing, [], {[1, 1]}), "nansen:InvalidParams");
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

        function roisOverlapAsDevFindsOverlappingRois(testCase)
            % as test_ophys.py's test_rois_overlap_as_dev_finds_overlapping_rois
            [columns, rows] = meshgrid(0:3, 0:3);
            square = sortrows([rows(:), columns(:)]);   % 16 pixels, row after row
            testCase.verifyTrue(nansen.internal.roisOverlap(square, square));
            testCase.verifyTrue(nansen.internal.roisOverlap(square, square(1:13, :)));
            testCase.verifyFalse(nansen.internal.roisOverlap(square, square + [0, 1]));   % 12 of 16: exactly 0.75 is not more
            line = [zeros(21, 1), (0:20)'];
            testCase.verifyFalse(nansen.internal.roisOverlap(line, [0, 0]));   % the centres 10 apart
            testCase.verifyTrue(nansen.internal.roisOverlap(line, [0, 1]));
            testCase.verifyFalse(nansen.internal.roisOverlap(zeros(0, 2), square));
        end

        function importsRoisReplacingAppendingOrAppendingThoseThatDoNotOverlap(testCase)
            % as test_ophys.py's test_rois_are_imported_replacing_appending_or_appending_those_that_do_not_overlap
            document = jsondecode(['{"imageSize": [10, 10], "rois": [{"id": 1, "pixels": [[1, 1], [1, 2], [2, 1], [2, 2]], ' ...
                '"classification": "accepted", "uid": "a", "links": [2]}, {"id": 2, "pixels": [[6, 6]], "cellType": "axon", "links": [1]}]}']);
            source = jsondecode(['{"imageSize": [20, 20], "rois": [{"id": 4, "pixels": [[1, 1], [1, 2], [2, 1], [2, 2]], "uid": "a"}, ' ...
                '{"id": 5, "pixels": [[8, 8], [8, 9], [12, 12]], "classification": "rejected", "uid": "b", "tags": ["x"], "links": [6, 9]}, ' ...
                '{"id": 6, "pixels": [[4, 4]], "cellType": "inhibitory", "links": [5]}, {"id": 7, "pixels": [[15, 15]]}]}']);
            ids = @(d) cellfun(@(r) double(r.id), d.rois);
            [appended, added] = nansen.internal.importRoisAt(document, 1, 1, source, "append");
            testCase.verifyEqual(added, {3, 4, 5});
            testCase.verifyEqual(ids(appended), [1, 2, 3, 4, 5]);
            testCase.verifyEqual(appended.rois{1}.classification, 'accepted');   % those it had stay as they were
            testCase.verifyEqual(string(appended.rois{2}.cellType), "axon");
            testCase.verifyFalse(isfield(appended.rois{3}, "uid"));   % the file has uid a already
            fourth = jsondecode(jsonencode(appended.rois{4}));
            testCase.verifyEqual(fourth.pixels, [8, 8; 8, 9]);
            testCase.verifyEqual(fourth.center, [8; 8.5]);
            testCase.verifyEqual(string(fourth.classification), "rejected");
            testCase.verifyEqual(string(fourth.uid), "b");
            testCase.verifyEqual(string(fourth.tags), "x");
            testCase.verifyEqual(fourth.links, 5);   % links among those imported, to their new ids
            testCase.verifyEqual(string(appended.rois{5}.cellType), "inhibitory");
            testCase.verifyEqual(appended.rois{5}.links, {4});
            [fewer, added] = nansen.internal.importRoisAt(document, 1, 1, source, "appendNonOverlapping");
            testCase.verifyEqual(added, {3, 4});
            testCase.verifyEqual(nansen.internal.roiPixels(fewer.rois{4}), [4, 4]);
            [replaced, added] = nansen.internal.importRoisAt(document, 1, 1, source, "replace");
            testCase.verifyEqual(added, {3, 4, 5});
            testCase.verifyEqual(ids(replaced), [3, 4, 5]);
            testCase.verifyEqual(string(replaced.rois{1}.uid), "a");
            fresh = nansen.internal.importRoisAt(struct("rois", {{}}), 1, 1, source, "append");
            testCase.verifyEqual(fresh.imageSize, [20, 20]);   % a new file takes the source's size
            testCase.verifyError(@() nansen.internal.importRoisAt(document, 1, 1, source, "merge"), "nansen:InvalidParams");
        end

        function importsRoisAtTheirPlace(testCase)
            document = jsondecode(['{"rois": [{"id": 1, "pixels": [[1, 1]], "plane": 1, "channel": 1}, ' ...
                '{"id": 2, "pixels": [[2, 2]], "plane": 2, "channel": 1}]}']);
            source = jsondecode(['{"rois": [{"id": 1, "pixels": [[5, 5]], "plane": 1, "channel": 1}, ' ...
                '{"id": 2, "pixels": [[6, 6]], "plane": 2, "channel": 1}]}']);
            [changed, added] = nansen.internal.importRoisAt(document, 2, 1, source, "replace");
            testCase.verifyEqual(added, {3});
            testCase.verifyEqual(cellfun(@(r) double(r.id), changed.rois), [1, 3]);
            testCase.verifyEqual(cellfun(@(r) double(r.plane), changed.rois), [1, 2]);
            testCase.verifyEqual(nansen.internal.roiPixels(changed.rois{2}), [6, 6]);
        end

        function aPreviewOnOneColumnGivesWhatTheWholeRunGivesForIt(testCase)
            % as test_ophys.py's test_a_preview_on_one_column_gives_what_the_whole_run_gives_for_it
            project = testCase.ophysProject();
            entity = project.entity("session", struct("subject_id", "m1", "session_id", "s2"));
            rng(4);
            traces = cumsum(0.1 * randn(300, 4), 1) + rand(300, 4) .^ 8 * 5;
            project.save(entity, "RoiSignals_Dff", traces);
            options = struct("frameRate", 30, "tauDecay", 0.4, "sparsity", 0.5);
            whole = project.run("ophys.deconvolve", {entity}, Options=options);
            spikes = project.load(entity, "RoiSignals_Deconvolved", Cached=false);
            calcium = project.load(entity, "RoiSignals_Denoised", Cached=false);
            one = nansen.internal.previewMethod(project, "ophys.deconvolve", entity, options, "", 20, 2, 100);
            testCase.verifyEqual(one.results{1}.noise, {whole{1}.noise{3}});
            testCase.verifyEqual(one.results{1}.spikeSum, {whole{1}.spikeSum{3}});
            names = string(cellfun(@(o) char(o.name), one.outputs, UniformOutput=false));
            deconvolved = one.outputs{names == "RoiSignals_Deconvolved"};
            denoised = one.outputs{names == "RoiSignals_Denoised"};
            testCase.verifyEqual(deconvolved.size, [300, 1]);
            rounded = @(column) num2cell(floor(column(1:3:end)' * 10000 + 0.5) / 10000);   % every third frame: 300 frames in 100 points
            testCase.verifyEqual(deconvolved.trace.frames, 300);
            testCase.verifyEqual(deconvolved.trace.step, 3);
            testCase.verifyEqual(deconvolved.trace.values, rounded(spikes(:, 3)));
            testCase.verifyEqual(denoised.trace.values, rounded(calcium(:, 3)));
            plain = nansen.internal.previewMethod(project, "ophys.deconvolve", entity, options, "", 5);
            testCase.verifyFalse(isfield(plain.outputs{1}, "trace"));   % only with a column
            testCase.verifyError(@() nansen.internal.previewMethod(project, "ophys.deconvolve", entity, options, "", 20, 4, 100), ...
                "nansen:InvalidParams");
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

        function cutsAStackToARangeOfFrames(testCase)
            data = reshape(0:59, 2, 3, 10);
            stack = nansen.Stack.fromArray(data);
            cut = stack.cut(4, 7);
            testCase.verifyEqual(size(cut), [2, 3, 4]);
            testCase.verifyEqual(cut.all(), data(:, :, 4:7));
            testCase.verifyEqual(cut.frames(2, 3), data(:, :, 5:6));
            later = cut.cut(2, Inf);
            testCase.verifyEqual(later.frames(1, 10), data(:, :, 5:7));
            testCase.verifyError(@() stack.cut(8, 7), "nansen:InvalidParams");
            testCase.verifyError(@() stack.cut(0, 3), "nansen:InvalidParams");
            testCase.verifyError(@() stack.cut(10, 11), "nansen:InvalidParams");
        end

        function methodsWorkOnARangeOfFrames(testCase)
            % as test_ophys.py's test_methods_work_on_a_range_of_frames
            project = testCase.ophysProject();
            entity = project.entity("session", struct("subject_id", "m1", "session_id", "s2"));
            fetch = @(name) project.load(entity, name, Cached=false);
            raw = double(project.load(entity, "TwoPhotonSeries_Original"));
            none = struct("stack", "TwoPhotonSeries_Original", "averageOutput", "", "maximumOutput", "", "frameStatsOutput", "");
            withRange = @(varargin) nansen.internal.mergeStructs(none, struct(varargin{:}));
            stats = project.run("ophys.image_stats", {entity}, Options=withRange("firstFrame", 5, "lastFrame", 24));
            part = raw(:, :, 5:24);
            testCase.verifyEqual(stats{1}.n_frames, 20);
            testCase.verifyEqual(stats{1}.mean_intensity, ophys.internal.roundTo(mean(part, "all"), 4));
            testCase.verifyEqual(stats{1}.max_intensity, max(part, [], "all"));
            stats = project.run("ophys.image_stats", {entity}, Options=withRange("firstFrame", 31));
            testCase.verifyEqual(stats{1}.n_frames, 10);   % lastFrame 0: to the last
            wrong = {{"firstFrame", 41}, {"lastFrame", 41}, {"firstFrame", 6, "lastFrame", 5}, {"firstFrame", 0}};
            for i = 1:numel(wrong)
                testCase.verifyError(@() project.run("ophys.image_stats", {entity}, Options=withRange(wrong{i}{:})), "nansen:InvalidOptions");
            end
            % the outputs have the frames processed
            moved = project.run("ophys.motion_correction", {entity}, Options=struct("stack", "TwoPhotonSeries_Original", ...
                "firstFrame", 11, "lastFrame", 30, "referenceFrames", 5));
            testCase.verifyEqual(moved{1}.frames, 20);
            testCase.verifyEqual(size(fetch("TwoPhotonSeries_Corrected")), [32, 32, 20]);
            testCase.verifyEqual(size(fetch("MotionCorrectionShifts")), [20, 2]);
            project.save(entity, "RoiArray", struct("imageSize", [32, 32], "rois", {{struct("id", 1, "pixels", {{[10, 10], [10, 11], [11, 10]}})}}));
            signals = project.run("ophys.extract_signals", {entity}, Options=struct("stack", "TwoPhotonSeries_Original", "firstFrame", 3, "lastFrame", 9));
            testCase.verifyEqual(signals{1}.frames, 7);
            testCase.verifyEqual(size(fetch("RoiSignals_MeanF")), [7, 1]);
            values = [squeeze(raw(11, 11, 3:9)); squeeze(raw(11, 12, 3:9)); squeeze(raw(12, 11, 3:9))];
            testCase.verifyEqual(signals{1}.meanSignal{1}, ophys.internal.roundTo(mean(values), 4));
            smoothed = project.run("ophys.denoise", {entity}, Options=struct("stack", "TwoPhotonSeries_Original", "firstFrame", 2, "lastFrame", 13));
            testCase.verifyEqual(smoothed{1}.frames, 12);
            testCase.verifyEqual(size(fetch("TwoPhotonSeries_Denoised")), [32, 32, 12]);
            binned = project.run("ophys.downsample", {entity}, Options=struct("stack", "TwoPhotonSeries_Original", "firstFrame", 9, "temporalFactor", 4));
            testCase.verifyEqual(binned{1}.frames, 8);
            % deinterleaving counts the frames put together: pairs 3..6 are frames 5..12
            pairs = project.run("ophys.deinterleave", {entity}, Options=struct("stack", "TwoPhotonSeries_Original", "channels", 2, "firstFrame", 3, "lastFrame", 6));
            testCase.verifyEqual(pairs{1}.frames, 4);
            both = fetch("TwoPhotonSeries_Deinterleaved");
            testCase.verifyEqual(size(both), [32, 32, 2, 4]);
            testCase.verifyEqual(double(both(:, :, 2, 1)), raw(:, :, 6));
            % crop and export, which had a range of their own, keep it
            cropped = project.run("ophys.crop", {entity}, Options=struct("stack", "TwoPhotonSeries_Original", "firstFrame", 4, "lastFrame", 8));
            testCase.verifyEqual(cropped{1}.frames, 5);
            testCase.verifyEqual(double(fetch("TwoPhotonSeries_Cropped")), raw(:, :, 4:8));
            % a preview runs on the first frames of the range, and refuses a range outside the whole recording
            preview = nansen.internal.previewMethod(project, "ophys.image_stats", entity, withRange("firstFrame", 21, "lastFrame", 40), "", 5);
            testCase.verifyEqual(preview.results{1}.n_frames, 5);
            testCase.verifyEqual(preview.results{1}.mean_intensity, ophys.internal.roundTo(mean(raw(:, :, 21:25), "all"), 4));
            preview = nansen.internal.previewMethod(project, "ophys.image_stats", entity, withRange("firstFrame", 39), "", 5);
            testCase.verifyEqual(preview.results{1}.n_frames, 2);
            testCase.verifyError(@() nansen.internal.previewMethod(project, "ophys.image_stats", entity, withRange("lastFrame", 41), "", 5), ...
                "nansen:InvalidOptions");
            % an image is one frame
            project.run("ophys.image_stats", {entity}, Options=struct("stack", "TwoPhotonSeries_Original"));
            image = project.run("ophys.image_stats", {entity}, Options=withRange("stack", "FovAverageProjection", "lastFrame", 1));
            testCase.verifyEqual(image{1}.n_frames, 1);
            testCase.verifyError(@() project.run("ophys.image_stats", {entity}, Options=withRange("stack", "FovAverageProjection", "firstFrame", 2)), ...
                "nansen:InvalidOptions");
        end

        function processesEveryPlaneInOneRunAsEachAlone(testCase)
            % as test_ophys.py's test_every_plane_is_processed_in_one_run_as_each_would_be_alone
            project = testCase.ophysProject();
            entity = project.entity("session", struct("subject_id", "m1", "session_id", "s2"));
            fetch = @(name) project.load(entity, name, Cached=false);
            run = @(method, options) project.run(method, {entity}, Options=options);
            raw = project.load(entity, "TwoPhotonSeries_Original");
            planes = reshape(cat(3, reshape(raw, 32, 32, 1, 40), reshape(circshift(raw(end:-1:1, :, :), 3, 3), 32, 32, 1, 40)), 32, 32, 1, 2, 40);
            project.save(entity, "Planes", planes);   % 32 x 32 x 1 channel x 2 planes x 40
            for name = ["Aligned", "Aligned1", "Aligned2"]   % the variables written a chunk at a time, as .npy
                project.save(entity, name, zeros(2, 2));
            end
            motion = struct("stack", "Planes", "referenceFrames", 5, "patches", 2, "subpixel", true, "bidirectionalCorrection", "constant");
            alone = cell(1, 2);
            for p = 1:2
                result = run("ophys.motion_correction", nansen.internal.mergeStructs(motion, struct("plane", p, "output", "Aligned" + p, "shiftsOutput", "Shifts" + p)));
                alone{p} = result{1};
            end
            every = run("ophys.motion_correction", nansen.internal.mergeStructs(motion, struct("plane", 0, "output", "Aligned", "shiftsOutput", "Shifts")));
            every = every{1};
            for p = 1:2
                testCase.verifyEqual(every.planes{p}, struct("plane", p, "maxShift", alone{p}.maxShift, "meanShift", alone{p}.meanShift, ...
                    "bidirectionalOffset", alone{p}.bidirectionalOffset));
            end
            testCase.verifyEqual(every.maxShift, max(alone{1}.maxShift, alone{2}.maxShift));
            aligned = fetch("Aligned");
            testCase.verifyEqual(size(aligned), [32, 32, 1, 2, 40]);   % as the recording: height x width x channels x planes x frames
            for p = 1:2
                testCase.verifyEqual(aligned(:, :, :, p, :), reshape(fetch("Aligned" + p), 32, 32, 1, 1, 40));
            end
            shifts = fetch("Shifts");
            testCase.verifyEqual(size(shifts), [40, 2, 8]);   % the planes' shifts joined along their last dimension
            testCase.verifyEqual(shifts(:, :, 5:8), fetch("Shifts2"));
            % image statistics: of them all and of each, the projections a frame per plane
            each = cell(1, 2);
            for p = 1:2
                result = run("ophys.image_stats", struct("stack", "Aligned", "plane", p, "averageOutput", "Average" + p, ...
                    "frameStatsOutput", "Stats" + p, "maximumOutput", ""));
                each{p} = result{1};
            end
            stats = run("ophys.image_stats", struct("stack", "Aligned", "plane", 0, "averageOutput", "Average", "frameStatsOutput", "Stats", "maximumOutput", ""));
            for p = 1:2
                testCase.verifyEqual([stats{1}.planes{p}.mean_intensity, stats{1}.planes{p}.max_intensity], [each{p}.mean_intensity, each{p}.max_intensity]);
            end
            average = fetch("Average");
            testCase.verifyEqual(size(project.openStack(entity, "Average")), [32, 32, 1, 2, 1]);   % the file keeps the frame
            testCase.verifyEqual(average(:, :, 1, 2), fetch("Average2"));
            frameStats = fetch("Stats");
            testCase.verifyEqual(frameStats(:, 5:8), fetch("Stats2"));
            frame = nansen.internal.imageFrame(project.openStack(entity, "Average"), 0, 0, "", [], 1);
            testCase.verifyEqual([frame.frames, frame.planes], [1, 2]);
            % ROIs of every plane in one file, with their places; the signals of each from its own plane
            options = struct("stack", "Aligned", "threshold", 0.3, "border", 3, "minSize", 4);
            found = cell(1, 2);
            for p = 1:2
                run("ophys.detect_rois", nansen.internal.mergeStructs(options, struct("plane", p)));
                found{p} = ophys.internal.roiList(fetch("RoiArray"));
            end
            detected = run("ophys.detect_rois", nansen.internal.mergeStructs(options, struct("plane", 0)));
            rois = ophys.internal.roiList(fetch("RoiArray"));
            testCase.verifyEqual(detected{1}.rois, numel(found{1}) + numel(found{2}));
            testCase.assertNotEmpty(found{1});
            testCase.assertNotEmpty(found{2});
            places = zeros(1, numel(rois));
            n = 0;
            for p = 1:2
                for i = 1:numel(found{p})
                    n = n + 1;
                    testCase.verifyEqual([rois{n}.id, rois{n}.plane, rois{n}.channel], [n, p, 1]);
                    testCase.verifyEqual(rois{n}.pixels, found{p}{i}.pixels);
                    places(n) = p;
                end
            end
            signals = run("ophys.extract_signals", struct("stack", "Aligned", "plane", 0));
            together = fetch("RoiSignals_MeanF");
            for p = 1:2
                testCase.verifyEqual(signals{1}.planes{p}, struct("plane", p, "rois", numel(found{p})));
                one = run("ophys.extract_signals", struct("stack", "Aligned", "plane", p, "output", "Signals" + p, "neuropilOutput", ""));
                testCase.verifyEqual(cell2mat(one{1}.ids), find(places == p));   % the ROIs of the plane, by their place
                testCase.verifyEqual(together(:, places == p), fetch("Signals" + p));
            end
            quick = run("ophys.quicky", struct("stack", "Aligned", "plane", 0, "roiDiameter", 4, "output", "Quick"));
            testCase.verifyEqual(cellfun(@(q) q.plane, quick{1}.planes), [1, 2]);
            testCase.verifyEqual(quick{1}.rois, sum(cellfun(@(q) q.rois, quick{1}.planes)));
            % ROIs without places are of every plane: not one plane's to extract
            project.save(entity, "Unplaced", struct("imageSize", [32, 32], "rois", {{struct("id", 1, "pixels", {{[3, 3]}})}}));
            testCase.verifyError(@() run("ophys.extract_signals", struct("stack", "Aligned", "plane", 0, "rois", "Unplaced")), "nansen:InvalidData");
            % of a stack without planes, plane 0 is its one plane
            testCase.verifyEqual(run("ophys.image_stats", struct("stack", "TwoPhotonSeries_Original", "plane", 0, "averageOutput", "")), ...
                run("ophys.image_stats", struct("stack", "TwoPhotonSeries_Original", "plane", 1, "averageOutput", "")));
            testCase.verifyError(@() run("ophys.denoise", struct("stack", "Aligned", "plane", 0)), "nansen:InvalidOptions");   % one plane at a time
        end

        function everyPlaneStoppedPartWayGoesOnToTheSameResult(testCase)
            % As Python's test_progress.py: plane 0 keeps every plane's state on the last dimension
            [project, entity] = testCase.longRecordingProject();   % 250 frames, put together as 2 planes of 125: 2 chunks per iteration
            project.run("ophys.deinterleave", {entity}, Options=struct("channels", 1, "planes", 2));
            options = struct("stack", "TwoPhotonSeries_Deinterleaved", "plane", 0, "referenceFrames", 20, "iterations", 2);
            whole = project.run("ophys.motion_correction", {entity}, Options=options);
            expected = OphysTest.outputBytes(project, entity, OphysTest.outputs());
            testCase.removeOutputs(project, entity, OphysTest.outputs());
            testCase.stopAfter(project, entity, "ophys.motion_correction", options, 1);   % after the first chunk
            state = OphysTest.progressOf(project, entity, "TwoPhotonSeries_Corrected");
            testCase.verifyEqual([state.pass, state.framesDone], [1, 100]);
            testCase.verifyEqual(reshape(state.state.total.shape, 1, []), [48, 48, 2]);
            testCase.stopAfter(project, entity, "ophys.motion_correction", options, 2);   % the first iteration's last chunk, one of the last
            state = OphysTest.progressOf(project, entity, "TwoPhotonSeries_Corrected");
            testCase.verifyEqual([state.pass, state.framesDone], [2, 100]);
            testCase.verifyEqual(reshape(state.state.shifts.shape, 1, []), [100, 2, 1, 1, 2]);
            context = nansen.MethodContext(Project=project);
            result = project.run("ophys.motion_correction", {entity}, Options=options, Context=context);
            testCase.verifyTrue(any(contains(context.Lines, "going on from frame 100 of iteration 2")));
            testCase.verifyEqual(result, whole);
            testCase.verifyEqual(OphysTest.outputBytes(project, entity, OphysTest.outputs()), expected);
        end

        function motionCorrectionStoppedPartWayGoesOnToTheSameResult(testCase)
            % As Python's test_progress.py: a run stopped part way (a crash, Cancel, the app closed) goes on
            % where it stopped (nansen.Checkpoint), to the aligned stack and shifts of a run that never stopped
            [project, entity] = testCase.longRecordingProject();   % 250 frames: 3 chunks per iteration
            settings = {struct("referenceFrames", 50, "iterations", 2), ...
                struct("referenceFrames", 30, "iterations", 3, "subpixel", true, "patches", 2, "maxShift", 4)};
            for k = 1:numel(settings)
                options = settings{k};
                whole = project.run("ophys.motion_correction", {entity}, Options=options);
                expected = OphysTest.outputBytes(project, entity, OphysTest.outputs());
                testCase.removeOutputs(project, entity, OphysTest.outputs());
                % stopped in the first iteration, after 2 of its 3 chunks
                testCase.stopAfter(project, entity, "ophys.motion_correction", options, 2);
                state = OphysTest.progressOf(project, entity, "TwoPhotonSeries_Corrected");
                testCase.verifyEqual([state.pass, state.passes, state.framesDone], [1, options.iterations, 200]);
                testCase.verifyEqual(sort(string(fieldnames(state.state)))', ["reference", "total"]);
                testCase.verifyEqual(string(state.method.id), "ophys.motion_correction");
                % going on, stopped again in the last iteration, after one chunk of it written
                lines = testCase.stopAfter(project, entity, "ophys.motion_correction", options, 1 + 3 * (options.iterations - 2) + 1);
                testCase.verifyTrue(any(contains(lines, "going on from frame 200 of iteration 1")));
                state = OphysTest.progressOf(project, entity, "TwoPhotonSeries_Corrected");
                testCase.verifyEqual([state.pass, state.framesDone], [options.iterations, 100]);
                testCase.verifyEqual(sort(string(fieldnames(state.state)))', ["reference", "shifts"]);
                % and to the end: the aligned stack and the shifts are those of the run that never stopped, byte for byte
                context = nansen.MethodContext(Project=project);
                result = project.run("ophys.motion_correction", {entity}, Options=options, Context=context);
                testCase.verifyTrue(any(contains(context.Lines, "going on from frame 100 of iteration " + options.iterations)));
                testCase.verifyEqual(result, whole);
                testCase.verifyEqual(OphysTest.outputBytes(project, entity, OphysTest.outputs()), expected);
                testCase.verifyEmpty(OphysTest.progressOf(project, entity, "TwoPhotonSeries_Corrected"));
                % complete, a run starts from the first frame again
                context = nansen.MethodContext(Project=project);
                project.run("ophys.motion_correction", {entity}, Options=options, Context=context);
                testCase.verifyFalse(any(contains(context.Lines, "going on")));
                testCase.verifyEqual(OphysTest.outputBytes(project, entity, OphysTest.outputs()), expected);
                testCase.removeOutputs(project, entity, OphysTest.outputs());
            end
        end

        function aRunWithOtherOptionsStartsOver(testCase)
            [project, entity] = testCase.longRecordingProject();
            testCase.stopAfter(project, entity, "ophys.motion_correction", struct("referenceFrames", 50), 4);
            state = OphysTest.progressOf(project, entity, "TwoPhotonSeries_Corrected");
            testCase.verifyEqual(state.pass, 2);
            context = nansen.MethodContext(Project=project);
            other = project.run("ophys.motion_correction", {entity}, Options=struct("referenceFrames", 40), Context=context);
            testCase.verifyFalse(any(contains(context.Lines, "going on")));
            testCase.verifyEmpty(OphysTest.progressOf(project, entity, "TwoPhotonSeries_Corrected"));
            expected = OphysTest.outputBytes(project, entity, OphysTest.outputs());
            testCase.removeOutputs(project, entity, OphysTest.outputs());
            testCase.verifyEqual(project.run("ophys.motion_correction", {entity}, Options=struct("referenceFrames", 40)), other);
            testCase.verifyEqual(OphysTest.outputBytes(project, entity, OphysTest.outputs()), expected);
        end

        function anOutputCutShortIsWrittenAgain(testCase)
            [project, entity] = testCase.longRecordingProject();
            options = struct("iterations", 1);
            project.run("ophys.motion_correction", {entity}, Options=options);
            expected = OphysTest.outputBytes(project, entity, OphysTest.outputs());
            testCase.removeOutputs(project, entity, OphysTest.outputs());
            testCase.stopAfter(project, entity, "ophys.motion_correction", options, 2);   % 200 frames written
            path = project.writePath(entity, "TwoPhotonSeries_Corrected");
            bytes = OphysTest.outputBytes(project, entity, "TwoPhotonSeries_Corrected");
            bytes = bytes{1};
            header = numel(bytes) - 48 * 48 * 2 * 200;
            fid = fopen(path, "w");
            fwrite(fid, bytes(1:header + 48 * 48 * 2 * 150), "uint8");   % frames lost: 150 of the 200 there
            fclose(fid);
            context = nansen.MethodContext(Project=project);
            project.run("ophys.motion_correction", {entity}, Options=options, Context=context);
            testCase.verifyFalse(any(contains(context.Lines, "going on")));   % started over
            testCase.verifyEqual(OphysTest.outputBytes(project, entity, OphysTest.outputs()), expected);
        end

        function arraysAreKeptExactly(testCase)
            values = randn(3, 4, 2);
            kept = nansen.Checkpoint.decode(jsondecode(jsonencode(nansen.Checkpoint.encode(values))));
            testCase.verifyEqual(kept, values);
            encoded = nansen.Checkpoint.encode(int32([1, 2, 3; 4, 5, 6]));
            testCase.verifyEqual(encoded.shape, [2, 3]);
            testCase.verifyEqual(string(encoded.dtype), "int32");
            testCase.verifyEqual(typecast(matlab.net.base64decode(string(encoded.data)), 'int32'), int32([1, 4, 2, 5, 3, 6]));
        end

        function otherStackWritersGoOnWhereTheyStopped(testCase)
            [project, entity] = testCase.longRecordingProject();
            runs = {"ophys.denoise", struct("stack", "TwoPhotonSeries_Original", "temporalSigma", 2, "spatialSigma", 1), "TwoPhotonSeries_Denoised"; ...
                "ophys.crop", struct("stack", "TwoPhotonSeries_Original", "firstRow", 3, "lastRow", 40, "firstFrame", 20, "lastFrame", 0), "TwoPhotonSeries_Cropped"; ...
                "ophys.deinterleave", struct("channels", 2, "planes", 1), "TwoPhotonSeries_Deinterleaved"};
            for k = 1:size(runs, 1)
                [method, options, output] = runs{k, :};
                whole = project.run(method, {entity}, Options=options);
                expected = OphysTest.outputBytes(project, entity, output);
                testCase.removeOutputs(project, entity, output);
                testCase.stopAfter(project, entity, method, options, 1);
                state = OphysTest.progressOf(project, entity, output);
                testCase.verifyGreaterThan(state.framesDone, 0, method);
                testCase.verifyEqual(project.run(method, {entity}, Options=options), whole, method);
                testCase.verifyEqual(OphysTest.outputBytes(project, entity, output), expected, method);
                testCase.verifyEmpty(OphysTest.progressOf(project, entity, output), method);
            end
        end

        function skipCompletedLeavesOutEntitiesWhoseOutputsAreThere(testCase)
            [project, entity] = testCase.longRecordingProject();
            s4 = project.entity("session", struct("subject_id", "m1", "session_id", "s4"));
            options = struct("referenceFrames", 10, "iterations", 1);
            project.run("ophys.motion_correction", {entity}, Options=options);
            testCase.verifyEqual(project.alreadyDone("ophys.motion_correction", {s4, entity}, options), [false, true]);
            api = nansen.Api(Project=project);
            keys = {struct("subject_id", "m1", "session_id", "s4"), struct("subject_id", "m1", "session_id", "s2")};
            response = api.handle(struct("id", 1, "method", "methods.run", "params", struct("methodId", "ophys.motion_correction", ...
                "entityType", "session", "keys", {keys}, "options", options, "skipCompleted", true)));
            testCase.verifyEqual(numel(response.result.results), 1);
            testCase.verifyEqual(string(response.result.skipped{1}.session_id), "s2");
            testCase.verifyEqual(project.alreadyDone("ophys.motion_correction", {s4, entity}, options), [true, true]);
            % an output gone, or still being written, is not done
            shifts = project.writePath(entity, "MotionCorrectionShifts");
            delete(shifts);
            testCase.verifyFalse(project.alreadyDone("ophys.motion_correction", {entity}));
            project.run("ophys.motion_correction", {entity}, Options=options);
            marker = nansen.Checkpoint.progressPath(project.writePath(entity, "TwoPhotonSeries_Corrected"));
            nansen.internal.writeText(marker, "{}");
            testCase.verifyFalse(project.alreadyDone("ophys.motion_correction", {entity}));
            delete(marker);
            testCase.verifyTrue(project.alreadyDone("ophys.motion_correction", {entity}));
            % a mark undone in the run journal takes it back
            nansen.internal.recordRuns(project.Folder, "ophys.motion_correction", "1.0.0", {entity}, "", "undone");
            testCase.verifyFalse(project.alreadyDone("ophys.motion_correction", {entity}));
            response = api.handle(struct("id", 2, "method", "methods.run", "params", struct("methodId", "ophys.motion_correction", ...
                "entityType", "session", "keys", {keys(2)}, "skipCompleted", "yes")));
            testCase.verifyEqual(string(response.error.code), "invalid-params");
        end

        function aTaskGoesOnWhereARunStoppedAndSkipsWhatIsDone(testCase)
            [project, entity] = testCase.longRecordingProject();
            s4 = project.entity("session", struct("subject_id", "m1", "session_id", "s4"));
            options = struct("referenceFrames", 50, "iterations", 2);
            project.run("ophys.motion_correction", {entity}, Options=options);
            expected = OphysTest.outputBytes(project, entity, OphysTest.outputs());
            testCase.removeOutputs(project, entity, OphysTest.outputs());
            project.run("ophys.motion_correction", {s4}, Options=options);
            testCase.stopAfter(project, entity, "ophys.motion_correction", options, 4);   % in its second iteration
            queue = nansen.TaskQueue(project);
            task = queue.submit("ophys.motion_correction", {s4, entity}, Options=options, SkipCompleted=true);
            testCase.verifyTrue(task.skipCompleted);
            done = queue.runNext();
            testCase.verifyEqual(string(done.status), "completed");
            skipped = nansen.internal.asCellOfStructs(done.skipped);
            testCase.verifyEqual(numel(skipped), 1);
            testCase.verifyEqual(string(skipped{1}.session_id), "s4");   % s4 had completed: left out
            testCase.verifyTrue(contains(queue.log(string(done.id)), "going on from frame 100 of iteration 2"));
            testCase.verifyEqual(OphysTest.outputBytes(project, entity, OphysTest.outputs()), expected);
            testCase.verifyEmpty(OphysTest.progressOf(project, entity, "TwoPhotonSeries_Corrected"));
            again = queue.retry(string(done.id));
            testCase.verifyTrue(again.skipCompleted);
            redo = queue.retry(string(done.id), SkipCompleted=false);
            testCase.verifyFalse(isfield(redo, "skipCompleted"));
            testCase.verifyEqual(numel(nansen.internal.asCellOfStructs(queue.runNext().skipped)), 2);   % both done now
            testCase.verifyEqual(string(queue.runNext().status), "completed");
        end

        function pointsGoToAnAlignedEntityAndBack(testCase)
            % as test_ophys.py's test_points_go_to_an_aligned_entity_and_back
            entry = struct("key", struct("session_id", "b"), "shift", [2, -3], "rotation", 2.5, "patches", 3, ...
                "rowShifts", [0, 1, 0, -1, 0, 1, 2, 0, -1], "columnShifts", [1, 0, 0, 0, -1, 0, 0, 1, 1]);
            points = [0, 0; 10.5, 33.25; 47, 49; -2, 50; 23.5, 24; 39.5, 7.5];
            there = nansen.internal.alignedPoints(points, entry, 48, 50);
            testCase.verifyLessThan(max(abs(nansen.internal.referencePoints(there, entry, 48, 50) - points), [], "all"), 1e-9);
            % the displacement field is the motion correction's: the patches' shifts at their centres, bilinear between them
            [columns, rows] = meshgrid(0:49, 0:47);
            field = nansen.internal.alignmentField([rows(:), columns(:)], entry, 48, 50);
            across = {ophys.internal.axisWeights(ophys.internal.patchEdges(48, 3), 48), ophys.internal.axisWeights(ophys.internal.patchEdges(50, 3), 50)};
            testCase.verifyEqual(reshape(field(:, 1), 48, 50), ophys.internal.shiftField(reshape(entry.rowShifts, 3, 3).', across{:}));
            testCase.verifyEqual(reshape(field(:, 2), 48, 50), ophys.internal.shiftField(reshape(entry.columnShifts, 3, 3).', across{:}));
            testCase.verifyEqual(nansen.internal.alignmentField([23.5, 24; 39.5, 7.5], entry, 48, 50), [0, -1; 2, 0]);
            % an ROI carried from an entity to itself stays; from the reference it goes where alignedPoints puts it
            reference = struct("key", struct("session_id", "a"), "shift", [0, 0], "rotation", 0);
            pixels = [20, 20; 20, 21; 21, 20; 21, 21];
            testCase.verifyEqual(nansen.internal.carriedPixels(pixels, entry, entry, 48, 50), pixels);
            testCase.verifyEqual(nansen.internal.carriedPixels(pixels, reference, entry, 48, 50), ...
                unique(floor(nansen.internal.alignedPoints(pixels, entry, 48, 50) + 0.5), "rows"));
            testCase.verifyEmpty(nansen.internal.carriedPixels([0, 0], reference, struct("shift", [-5, -5], "rotation", 0), 48, 50));
            testCase.verifyEqual(nansen.internal.alignmentEntry(struct("entities", {{reference, entry}}), struct("subject_id", "m1", "session_id", "b")), entry);
            testCase.verifyEmpty(nansen.internal.alignmentEntry(struct("entities", {{reference, entry}}), struct("session_id", "c")));
        end

        function anEditIsMirroredToAnAlignedEntity(testCase)
            % as test_ophys.py's test_an_edit_is_mirrored_to_an_aligned_entity
            source = struct("shift", [0, 0], "rotation", 0);
            target = struct("shift", [1, 2], "rotation", 0);
            before = nansen.internal.roiOutlines(jsondecode(['{"rois": [{"id": 1, "pixels": [[3, 3]]}, {"id": 2, "pixels": [[5, 5]]}, ' ...
                '{"id": 3, "pixels": [[7, 7]]}, {"id": 4, "pixels": [[9, 9]]}]}']));
            after = nansen.internal.roiOutlines(jsondecode(['{"rois": [{"id": 1, "pixels": [[3, 4]]}, ' ...
                '{"id": 2, "pixels": [[5, 5]], "classification": "rejected"}, {"id": 4, "pixels": [[19, 19]]}, ' ...
                '{"id": 6, "pixels": [[1, 1], [1, 2]], "classification": "accepted"}, {"id": 7, "pixels": [[2, 2]]}]}']));
            here = jsondecode(['{"imageSize": [20, 20], "rois": [{"id": 1, "pixels": [[4, 5]], "cellType": "axon", "plane": 1, "channel": 1}, ' ...
                '{"id": 2, "pixels": [[6, 7]], "plane": 1, "channel": 1}, {"id": 3, "pixels": [[8, 9]], "plane": 1, "channel": 1}, ' ...
                '{"id": 4, "pixels": [[10, 11]], "plane": 1, "channel": 1}, {"id": 5, "pixels": [[0, 0]], "plane": 1, "channel": 1}, ' ...
                '{"id": 7, "pixels": [[0, 1]], "plane": 2, "channel": 1}]}']);
            [document, summary] = nansen.internal.mirrorRoisAt(here, 1, 1, before, after, source, target, [20, 20]);
            summary = jsondecode(jsonencode(summary));
            testCase.verifyEqual(summary.added, 6);
            testCase.verifyEqual(summary.changed(:)', [1, 2]);
            testCase.verifyEqual(summary.removed(:)', [3, 4]);
            document = jsondecode(jsonencode(document));   % as the file has it
            rois = nansen.internal.asCellOfStructs(document.rois);
            ids = cellfun(@(r) r.id, rois);
            testCase.verifyEqual(sort(ids), [1, 2, 5, 6, 7]);
            one = rois{ids == 1};
            testCase.verifyEqual(nansen.internal.roiPixels(one), [4, 6]);
            testCase.verifyEqual(string(one.cellType), "axon");
            two = rois{ids == 2};
            testCase.verifyEqual(string(two.classification), "rejected");
            testCase.verifyEqual(nansen.internal.roiPixels(two), [6, 7]);
            six = rois{ids == 6};
            testCase.verifyEqual(nansen.internal.roiPixels(six), [2, 3; 2, 4]);
            testCase.verifyEqual(string(six.classification), "accepted");
            testCase.verifyEqual([six.plane, six.channel], [1, 1]);
            seven = rois{ids == 7};
            testCase.verifyEqual(seven.plane, 2);
        end

        function roisFollowAFieldOfViewThatBendsAndEditsAreMirrored(testCase)
            % as test_ophys.py's test_rois_follow_a_field_of_view_that_bends_only_with_patches (the ground truth is
            % checked by the ophys-motion conformance case)
            folder = fullfile(testCase.Folder, "motion");
            copyfile(fullfile(nansen.internal.repoRoot(), "conformance", "api", "ophys-motion", "project"), folder);
            project = nansen.Project.open(folder);
            project.scan();
            project.sync("subject");
            project.sync("session");
            project.runTool("ophys.setup_variables", Options=struct("rawFilePattern", "recording", "rawFileAdapter", "npy", "addColumns", false));
            api = nansen.Api(Project=project);
            s8 = struct("subject_id", "m1", "session_id", "s8");
            s9 = struct("subject_id", "m1", "session_id", "s9");
            call = @(method, params) api.handle(struct("id", 1, "method", method, "params", params));
            align = @(patches) call("methods.run", struct("methodId", "ophys.align_sessions", "entityType", "session", "keys", {{s8, s9}}, ...
                "options", struct("image", "TwoPhotonSeries_Original", "maxShift", 6, "patches", patches, "maxDeviation", 2)));
            response = align(3);
            results = nansen.internal.asCellOfStructs(response.result.results);
            shifts = nansen.internal.asCellOfStructs(results{1}.shifts);
            testCase.verifyEqual(shifts{2}.shift, [-2, 3]);
            testCase.verifyEqual(shifts{2}.rowShifts, [0, 1, 0, 0, 0, -1, 1, 0, 0]);
            testCase.verifyEqual(shifts{2}.columnShifts, [1, 0, 0, 0, 0, 0, 0, -1, 1]);
            alignment = project.load(project.entity("session", s8), "RoiArray", Cached=false).alignment;
            testCase.verifyEqual(string(alignment.reference.session_id), "s8");
            % an ROI added in s9 with mirror goes to s8; an undo (a restore of what there was) with mirror takes it out again
            update = @(key, more) call("rois.update", nansen.internal.mergeStructs(struct("entityType", "session", "key", key, "variable", "RoiArray"), more));
            before = update(s9, struct()).result.rois;
            added = update(s9, struct("add", {{struct("pixels", [40, 40; 40, 41])}}, "mirror", true)).result;
            testCase.verifyEqual(added.added, {4});
            mirrored = jsondecode(jsonencode(added.mirrored));
            testCase.verifyEqual(string(mirrored.key.session_id), "s8");
            testCase.verifyEqual(mirrored.added, 4);
            undone = update(s9, struct("restore", {before}, "mirror", true)).result;
            mirrored = jsondecode(jsonencode(undone.mirrored));
            testCase.verifyEqual(mirrored.removed, 4);
            rois = nansen.internal.asCellOfStructs(project.load(project.entity("session", s8), "RoiArray", Cached=false).rois);
            testCase.verifyEqual(cellfun(@(r) r.id, rois), [1, 2, 3]);
            % aligned again, s9's classification is kept; with existingRois replace it is not
            update(s9, struct("classify", struct("id", 2, "classification", "accepted")));
            response = align(3);
            results = nansen.internal.asCellOfStructs(response.result.results);
            testCase.verifyEqual(results{1}.kept, 1);
            rois = nansen.internal.asCellOfStructs(project.load(project.entity("session", s9), "RoiArray", Cached=false).rois);
            testCase.verifyEqual(string(rois{2}.classification), "accepted");
            response = call("methods.run", struct("methodId", "ophys.align_sessions", "entityType", "session", "keys", {{s8, s9}}, ...
                "options", struct("image", "TwoPhotonSeries_Original", "maxShift", 6, "existingRois", "replace")));
            results = nansen.internal.asCellOfStructs(response.result.results);
            testCase.verifyEqual(results{1}.kept, 0);
            rois = nansen.internal.asCellOfStructs(project.load(project.entity("session", s9), "RoiArray", Cached=false).rois);
            testCase.verifyFalse(isfield(rois{2}, "classification"));
            % no alignment, nothing to mirror to
            s1 = struct("subject_id", "m1", "session_id", "s1");
            testCase.verifyEqual(string(update(s1, struct("add", {{struct("pixels", [1, 1])}}, "mirror", true)).error.code), "invalid-params");
        end
    end

    methods (Access = private)
        function project = ophysProject(testCase)
            %ophysProject The ophys conformance project, its TIFF recordings read as TwoPhotonSeries_Original (s2: 32 x 32 x 40)
            folder = fullfile(testCase.Folder, "project");
            copyfile(fullfile(nansen.internal.repoRoot(), "conformance", "api", "ophys", "project"), folder);
            project = nansen.Project.open(folder);
            project.scan();
            project.sync("subject");
            project.sync("session");
            project.runTool("ophys.setup_variables", Options=struct("rawFilePattern", "tiff", "rawFileAdapter", "ophys.tiff_stack"));
        end

        function [project, entity] = longRecordingProject(testCase)
            %longRecordingProject The ophys conformance project, with session s2's recording replaced by a longer one
            %in three files (as StackTest's), read as TwoPhotonSeries_Original
            folder = fullfile(testCase.Folder, "project");
            copyfile(fullfile(nansen.internal.repoRoot(), "conformance", "api", "ophys", "project"), folder);
            project = nansen.Project.open(folder);
            project.scan();
            project.sync("subject");
            project.sync("session");
            project.runTool("ophys.setup_variables", Options=struct("rawFilePattern", "tiff", "rawFileAdapter", "ophys.tiff_stack"));
            rng(7);
            frames = 250;
            scene = 300 + 40 * randn(48, 48);
            stack = repmat(scene, 1, 1, frames);
            shifts = randi([-2, 2], frames, 2);
            for t = 1:frames
                stack(:, :, t) = circshift(stack(:, :, t), shifts(t, :));
            end
            stack = uint16(max(0, stack + 5 * randn(size(stack))));
            raw = fullfile(project.Folder, "data", "raw", "sub-m1", "ses-s2");
            delete(fullfile(raw, "*.tif"));
            bounds = [0, 90, 170, frames];
            for n = 1:3
                ophys.TiffStack().write(fullfile(raw, "rec_" + n + ".tif"), stack(:, :, bounds(n) + 1:bounds(n + 1)));
            end
            project.scan();
            entity = project.entity("session", struct("subject_id", "m1", "session_id", "s2"));
        end

        function lines = stopAfter(testCase, project, entity, method, options, chunks)
            %stopAfter Run the method, cancelled after it has done the given number of chunks (as a crash, Cancel or
            %the app closed would stop it); its log lines
            context = nansen.MethodContext(Project=project);
            counter = containers.Map({'n'}, {0});
            context.OnProgress = @(~, ~) OphysTest.tick(counter, context, chunks);
            testCase.verifyError(@() project.run(method, {entity}, Options=options, Context=context), "nansen:Cancelled");
            lines = context.Lines;
        end

        function removeOutputs(testCase, project, entity, names)
            for name = string(names)
                path = project.writePath(entity, name);
                delete(path);
                testCase.verifyFalse(isfile(nansen.Checkpoint.progressPath(path)), name);   % complete: no progress left
            end
        end
    end

    methods (Static)
        function names = outputs()
            names = ["TwoPhotonSeries_Corrected", "MotionCorrectionShifts"];
        end

        function tick(counter, context, limit)
            counter('n') = counter('n') + 1;
            if counter('n') >= limit
                context.cancel();
            end
        end

        function bytes = outputBytes(project, entity, names)
            names = string(names);
            bytes = cell(1, numel(names));
            for i = 1:numel(names)
                fid = fopen(project.writePath(entity, names(i)), "r");
                bytes{i} = fread(fid, Inf, "*uint8");
                fclose(fid);
            end
        end

        function state = progressOf(project, entity, name)
            %progressOf The progress document beside the variable's file, or [] when there is none
            state = [];
            path = nansen.Checkpoint.progressPath(project.writePath(entity, name));
            if isfile(path)
                state = jsondecode(fileread(path));
            end
        end

        function pixels = pixelsOf(mask)
            % [row, column] (0-based) of a mask's pixels, in row-major order as NumPy lists them
            [rows, columns] = find(mask);
            pixels = sortrows([rows, columns] - 1);
        end
    end
end
