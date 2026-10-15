classdef ExternalToolsTest < matlab.unittest.TestCase
%ExternalToolsTest The ophys module's MATLAB wrappers run against the real tools
%
%   runExternalToolTests puts NoRMCorre, CaImAn-MATLAB, EXTRACT,
%   Flow-Registration and dev's imviewer on the path (CI's External tools
%   job clones them) and runs these tests; a tool that is missing fails its
%   test there. Each runs a wrapper on a synthetic recording with cells at
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
            ophys.TiffStack().write(fullfile(folder, "data", "raw", "sub-m1", "ses-s2", "rec.tif"), moving);
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

        function [stack, centers] = separateCells()
            %separateCells 128 x 128 x 600 frames: 12 cells (radius 5) on a 3 x 4 grid, 28 px apart, with
            %calcium transients on a smooth background
            rng(2);
            sz = 128;
            frames = 600;
            [xx, yy] = meshgrid(1:sz, 1:sz);
            stack = repmat(300 + 50 * (xx + yy) / sz, 1, 1, frames);
            [cy, cx] = ndgrid([36, 64, 92], [22, 50, 78, 106]);
            centers = [cy(:), cx(:)] + randi([-2, 2], 12, 2);
            for i = 1:size(centers, 1)
                spikes = (rand(1, frames) < 0.03) * 600;
                trace = filter(1, [1, -exp(-1 / 8)], spikes);
                mask = (yy - centers(i, 1)) .^ 2 + (xx - centers(i, 2)) .^ 2 <= 25;
                stack = stack + mask .* reshape(trace, 1, 1, []);
            end
            stack = uint16(max(0, stack + 10 * randn(size(stack))));
        end
    end

    methods (Test)
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
            % EXTRACT gets a recording of its own: separate cells on a smooth background (on the shared one,
            % with overlapping cells on a fine texture, it finds about half of them)
            [stack, centers] = ExternalToolsTest.separateCells();
            testCase.Project.save(testCase.Session, "TwoPhotonSeries_Corrected", stack);
            testCase.Centers = centers;
            result = testCase.Project.run("ophys.extract", {testCase.Session}, ...
                Options=struct("stack", "TwoPhotonSeries_Corrected", "cellRadius", 5));
            testCase.verifyGreaterThanOrEqual(result{1}.rois, 8);
            rois = ophys.internal.roiList(testCase.Project.load(testCase.Session, "RoiArray", Cached=false));
            centersFound = cell2mat(cellfun(@(r) reshape(double(r.center), 1, 2) + 1, rois(:), UniformOutput=false));
            matched = 0;
            for i = 1:size(testCase.Centers, 1)
                matched = matched + any(vecnorm(centersFound - testCase.Centers(i, :), 2, 2) <= 4);
            end
            testCase.verifyGreaterThanOrEqual(matched, 8, sprintf("EXTRACT's centres (row, column):%s\ntrue centres:%s", ...
                sprintf(" (%.1f, %.1f)", centersFound.'), sprintf(" (%d, %d)", testCase.Centers.')));
            testCase.verifySize(testCase.Project.load(testCase.Session, "RoiSignals_MeanF", Cached=false), [size(stack, 3), numel(rois)]);
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
