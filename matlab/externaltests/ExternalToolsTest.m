classdef ExternalToolsTest < matlab.unittest.TestCase
%ExternalToolsTest The ophys module's MATLAB wrappers run against the real tools
%
%   runExternalToolTests puts NoRMCorre, CaImAn-MATLAB, EXTRACT,
%   Flow-Registration, Suite2P, DeepInterpolation-MATLAB and dev's imviewer
%   on the path (CI's External tools job clones them) and runs these tests;
%   a tool that is missing fails its test there (DeepInterpolation's test
%   is skipped, with its reason, without the Deep Learning Toolbox). Each runs a wrapper on a synthetic recording with cells at
%   known places and known rigid motion.

    properties
        Project
        Session
        Centers
        Shifts
        Clean
    end

    methods (TestMethodSetup)
        function makeProject(testCase)
            testCase.applyFixture(matlab.unittest.fixtures.PathFixture( ...
                fullfile(nansen.internal.repoRoot(), "modules", "ophys", "matlab")));
            fixture = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture);
            folder = fullfile(fixture.Folder, "project");
            copyfile(fullfile(nansen.internal.repoRoot(), "conformance", "api", "ophys", "project"), folder);
            [moving, clean, centers, shifts] = ExternalToolsTest.recording();
            session = fullfile(folder, "data", "raw", "sub-m1", "ses-s2");
            delete(fullfile(session, "*.tif"));   % the case's recording, in two files: replaced by this one
            ophys.TiffStack().write(fullfile(session, "rec.tif"), moving);
            project = nansen.Project.open(folder);
            project.scan();
            project.sync("subject");
            project.sync("session");
            project.runTool("ophys.setup_variables", Options=struct("rawFilePattern", "tiff", "rawFileAdapter", "ophys.tiff_stack"));
            testCase.Session = project.entity("session", struct("subject_id", "m1", "session_id", "s2"));
            project.save(testCase.Session, "TwoPhotonSeries_Corrected", clean);
            testCase.Project = project;
            testCase.Centers = centers;
            testCase.Shifts = shifts;
            testCase.Clean = clean;
        end
    end

    methods (Static)
        function [moving, clean, centers, shifts] = recording()
            %recording 128 x 128 x 300 frames: 15 round cells (radius 4) with calcium transients on a
            %textured background, and the same moved by known whole-pixel shifts
            rng(0);
            sz = 128;
            frames = 300;
            [xx, yy] = meshgrid(1:sz, 1:sz);
            background = 300 + 120 * conv2(randn(sz + 2), ones(3) / 9, "valid");
            clean = repmat(background, 1, 1, frames);
            centers = randi([15, sz - 15], 15, 2);
            for i = 1:size(centers, 1)
                spikes = (rand(1, frames) < 0.03) * 800;
                trace = filter(1, [1, -exp(-1 / 8)], spikes);
                mask = (yy - centers(i, 1)) .^ 2 + (xx - centers(i, 2)) .^ 2 <= 16;
                clean = clean + mask .* reshape(trace, 1, 1, []);
            end
            clean = uint16(max(0, clean + 10 * randn(size(clean))));
            shifts = [round(3 * sin((1:frames)' / 20)), round(2 * cos((1:frames)' / 30))];
            moving = clean;
            for t = 1:frames
                moving(:, :, t) = circshift(clean(:, :, t), shifts(t, :));
            end
        end

        function [stack, centers] = simulatedByExtract()
            %simulatedByExtract 128 x 128 x 1000 frames from EXTRACT's own simulator (simulate_data): 12 cells
            %of radius 4-6 at least 20 px apart, an event per 50 frames (tau 10) at 8 x the noise
            rng(3);
            [movie, ~, ~, ~, ~, centers] = feval("simulate_data", [128, 128, 1000], 12, [4, 6], 20, 0.02, 10, 8, 0.02, 0, 1, 0);
            stack = uint16(round(1000 * (movie + 1)));
        end
    end

    methods (Test)
        function cnmfFindsTheCells(testCase)
            result = testCase.Project.run("ophys.cnmf", {testCase.Session}, Options=struct("components", 20, "cellRadius", 4, "frameRate", 30));
            testCase.verifyEqual(result{1}.frames, 300);
            rois = ophys.internal.roiList(testCase.Project.load(testCase.Session, "RoiArray", Cached=false));
            centers = cell2mat(cellfun(@(r) reshape(double(r.center), 1, 2) + 1, rois(:), UniformOutput=false));   % 1-based like Centers
            found = sum(arrayfun(@(i) any(vecnorm(centers - testCase.Centers(i, :), 2, 2) <= 4), 1:size(testCase.Centers, 1)));
            testCase.verifyGreaterThanOrEqual(found, 10);
            testCase.verifySize(testCase.Project.load(testCase.Session, "RoiSignals_MeanF"), [300, numel(rois)]);
            testCase.verifySize(testCase.Project.load(testCase.Session, "RoiSignals_Denoised"), [300, numel(rois)]);
        end

        function exportNwbWritesTheStackRoisAndSignals(testCase)
            % ophys.exportNwb with matnwb, read back with nwbRead (Python's test_external_tools reads its own with pynwb)
            project = testCase.Project;
            project.run("ophys.detect_rois", {testCase.Session});
            document = project.load(testCase.Session, "RoiArray");
            rois = ophys.internal.roiList(document);
            rois{1}.classification = 'rejected';
            document.rois = rois;
            project.save(testCase.Session, "RoiArray", document);
            project.run("ophys.extract_signals", {testCase.Session});   % the rejected ROI left out of the signals
            project.run("ophys.compute_dff", {testCase.Session});
            path = fullfile(project.Folder, "out.nwb");
            result = project.run("ophys.export_nwb", {testCase.Session}, Options=struct("path", path, "frameRate", 30));
            result = result{1};
            testCase.verifyEqual([result.frames, result.rois], [300, numel(rois)]);
            testCase.verifyEqual(string(result.signals), ["RoiSignals_MeanF", "RoiSignals_Dff"]);
            nwb = nwbRead(char(path), 'ignorecache');
            data = nwb.acquisition.get('TwoPhotonSeries').data.load();
            testCase.verifyEqual(size(data), [128, 128, 300]);   % (frames, x, y) in the file
            testCase.verifyEqual(data, testCase.Clean);
            module = nwb.processing.get('ophys');
            segmentation = module.nwbdatainterface.get('ImageSegmentation').planesegmentation.get('PlaneSegmentation');
            ids = cellfun(@(r) double(r.id), rois);
            testCase.verifyEqual(double(segmentation.id.data.load()), ids(:));
            signals = module.nwbdatainterface.get('Fluorescence').roiresponseseries.get('RoiResponseSeries');
            testCase.verifyEqual(signals.data.load(), project.load(testCase.Session, "RoiSignals_MeanF")', AbsTol=1e-9);
            testCase.verifyEqual(double(signals.rois.data.load()), (1:numel(rois) - 1)');
        end

        function normcorreRecoversTheShifts(testCase)
            result = testCase.Project.run("ophys.normcorre", {testCase.Session}, ...
                Options=struct("stack", "TwoPhotonSeries_Original", "maxShift", 8));
            testCase.verifyEqual(result{1}.frames, 300);
            found = testCase.Project.load(testCase.Session, "MotionCorrectionShifts", Cached=false);
            testCase.verifySize(found, [300, 2]);
            for axis = 1:2   % NoRMCorre's sign and offset are its own: the shifts follow the true ones
                c = corrcoef(found(:, axis), testCase.Shifts(:, axis));
                testCase.verifyGreaterThan(abs(c(1, 2)), 0.9, sprintf("axis %d", axis));
            end
            aligned = testCase.Project.load(testCase.Session, "TwoPhotonSeries_Corrected", Cached=false);
            testCase.verifyClass(aligned, "uint16");
            testCase.verifyLessThan(ExternalToolsTest.wobble(aligned), ExternalToolsTest.wobble( ...
                testCase.Project.load(testCase.Session, "TwoPhotonSeries_Original")));
        end

        function flowregAlignsTheFrames(testCase)
            result = testCase.Project.run("ophys.flowreg", {testCase.Session}, ...
                Options=struct("stack", "TwoPhotonSeries_Original", "quality", "fast", "referenceFrames", 50));
            testCase.verifyEqual(result{1}.frames, 300);
            aligned = testCase.Project.load(testCase.Session, "TwoPhotonSeries_Corrected", Cached=false);
            testCase.verifySize(aligned, [128, 128, 300]);
            testCase.verifyLessThan(ExternalToolsTest.wobble(aligned), ExternalToolsTest.wobble( ...
                testCase.Project.load(testCase.Session, "TwoPhotonSeries_Original")));
        end

        function extractFindsTheCells(testCase)
            % EXTRACT gets a recording from its own simulator: on the shared one's flat, very bright disks it
            % fits rings around the cells and keeps noise
            [stack, centers] = ExternalToolsTest.simulatedByExtract();
            testCase.Project.save(testCase.Session, "TwoPhotonSeries_Corrected", stack);
            testCase.Centers = centers;
            result = testCase.Project.run("ophys.extract", {testCase.Session}, ...
                Options=struct("stack", "TwoPhotonSeries_Corrected", "cellRadius", 5));
            testCase.verifyEqual(result{1}.rois, 12);   % every cell, and nothing else
            rois = ophys.internal.roiList(testCase.Project.load(testCase.Session, "RoiArray", Cached=false));
            centersFound = cell2mat(cellfun(@(r) reshape(double(r.center), 1, 2) + 1, rois(:), UniformOutput=false));
            matched = 0;
            for i = 1:size(testCase.Centers, 1)
                matched = matched + any(vecnorm(centersFound - testCase.Centers(i, :), 2, 2) <= 4);
            end
            testCase.verifyEqual(matched, 12, sprintf("EXTRACT's centres (row, column):%s\ntrue centres:%s", ...
                sprintf(" (%.1f, %.1f)", centersFound.'), sprintf(" (%d, %d)", testCase.Centers.')));
            testCase.verifySize(testCase.Project.load(testCase.Session, "RoiSignals_MeanF", Cached=false), [size(stack, 3), numel(rois)]);
        end

        function suite2pFindsTheCells(testCase)
            % the MATLAB Suite2P on the moving recording: reg2P registers it, sourcery finds the cells, and
            % wrapperDECONV deconvolves with CaImAn-MATLAB's oasisAR1 (as Python's test_external_tools runs suite2p)
            result = testCase.Project.run("ophys.suite2p", {testCase.Session}, Options=struct( ...
                "stack", "TwoPhotonSeries_Original", "framesPerSecond", 30, "cellDiameter", 8, "onlyCells", false));
            testCase.verifyEqual(result{1}.frames, 300);
            testCase.verifyGreaterThanOrEqual(result{1}.rois, 10);
            rois = ophys.internal.roiList(testCase.Project.load(testCase.Session, "RoiArray", Cached=false));
            testCase.verifyNumElements(rois, result{1}.rois);
            centersFound = cell2mat(cellfun(@(r) reshape(double(r.center), 1, 2) + 1, rois(:), UniformOutput=false));
            matched = 0;
            for i = 1:size(testCase.Centers, 1)
                matched = matched + any(vecnorm(centersFound - testCase.Centers(i, :), 2, 2) <= 4);
            end
            testCase.verifyGreaterThanOrEqual(matched, 10);
            for name = ["RoiSignals_MeanF", "RoiSignals_NeuropilF", "RoiSignals_Deconvolved"]
                testCase.verifySize(testCase.Project.load(testCase.Session, name, Cached=false), [300, numel(rois)], name);
            end
        end

        function deepInterpolationPredictsFrames(testCase)
            % DeepInterpolation-MATLAB's deepinterp.Net with an untrained network of the Deep Learning Toolbox, saved
            % as a .mat file (Python's test_external_tools saves an untrained Keras model)
            testCase.assumeTrue(exist("assembleNetwork", "file") > 0 && exist("regressionLayer", "file") > 0, ...
                "the Deep Learning Toolbox (assembleNetwork, regressionLayer) is not installed, which DeepInterpolation's networks need");
            before = 3;
            after = 3;
            layers = [imageInputLayer([128, 128, before + after], Normalization="none"), ...
                convolution2dLayer(3, 1, Padding="same", Weights=ones(3, 3, before + after, 1) / (9 * (before + after)), Bias=0), ...
                regressionLayer];
            net = assembleNetwork(layers); %#ok<NASGU>
            model = fullfile(testCase.Project.Folder, "model.mat");
            save(model, "net");
            result = testCase.Project.run("ophys.deep_interpolation", {testCase.Session}, Options=struct( ...
                "stack", "TwoPhotonSeries_Original", "modelPath", model, "preFrames", before, "postFrames", after));
            result = result{1};
            testCase.verifyEqual(result.frames, 300);
            testCase.verifyEqual(result.predicted, 300 - before - after);
            out = testCase.Project.load(testCase.Session, "TwoPhotonSeries_Denoised", Cached=false);
            original = testCase.Project.load(testCase.Session, "TwoPhotonSeries_Original");
            testCase.verifyClass(out, "single");
            testCase.verifySize(out, [128, 128, 300]);
            testCase.verifyEqual(out(:, :, 1:before), single(original(:, :, 1:before)));   % too close to the start: kept
            testCase.verifyGreaterThan(max(abs(out(:, :, before + 1) - single(original(:, :, before + 1))), [], "all"), 1);
        end

        function caimanDeconvolvesTraces(testCase)
            rng(1);
            spikes = double(rand(300, 3) < 0.03);
            calcium = filter(1, [1, -0.95], spikes);
            testCase.Project.save(testCase.Session, "RoiSignals_Dff", calcium + 0.05 * randn(size(calcium)));
            result = testCase.Project.run("ophys.caiman_deconvolution", {testCase.Session});
            testCase.verifyEqual(result{1}.rois, 3);
            found = testCase.Project.load(testCase.Session, "RoiSignals_Deconvolved", Cached=false);
            testCase.verifySize(found, [300, 3]);
            for i = 1:3
                c = corrcoef(found(:, i), spikes(:, i));
                testCase.verifyGreaterThan(c(1, 2), 0.5);
            end
        end

        function flufinderFindsTheCells(testCase)
            result = testCase.Project.run("ophys.flufinder", {testCase.Session}, ...
                Options=struct("stack", "TwoPhotonSeries_Corrected", "roiDiameter", 8));
            testCase.verifyGreaterThanOrEqual(result{1}.rois, 8);
            rois = ophys.internal.roiList(testCase.Project.load(testCase.Session, "RoiArray", Cached=false));
            centersFound = cell2mat(cellfun(@(r) reshape(double(r.center), 1, 2) + 1, rois(:), UniformOutput=false));
            matched = 0;
            for i = 1:size(testCase.Centers, 1)
                matched = matched + any(vecnorm(centersFound - testCase.Centers(i, :), 2, 2) <= 4);
            end
            testCase.verifyGreaterThanOrEqual(matched, 8);
        end

        function imviewerOpensTheStack(testCase)
            if ~isMATLABReleaseOlderThan("R2025a")   % no Java figures: the wrapper says so
                testCase.verifyError(@() testCase.Project.run("ophys.open_in_imviewer", {testCase.Session}, ...
                    Options=struct("stack", "TwoPhotonSeries_Corrected")), "nansen:DependencyMissing");
                return
            end
            before = findall(groot, "Type", "figure");
            result = testCase.Project.run("ophys.open_in_imviewer", {testCase.Session}, ...
                Options=struct("stack", "TwoPhotonSeries_Corrected"));
            testCase.verifyTrue(result{1}.opened);
            opened = setdiff(findall(groot, "Type", "figure"), before);
            testCase.verifyNotEmpty(opened);
            delete(opened);
        end
    end

    methods (Static, Access = private)
        function value = wobble(stack)
            %wobble How far frames are from their average: the mean absolute difference
            stack = double(stack(9:end - 8, 9:end - 8, :));   % away from the edges shifts fill
            value = mean(abs(stack - mean(stack, 3)), "all");
        end
    end
end
