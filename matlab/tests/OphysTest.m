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
    end

    methods (Access = private)
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
