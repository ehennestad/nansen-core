classdef FormatsTest < matlab.unittest.TestCase
%FormatsTest The ophys module's readers of other tools' files, on the files conformance/files/ophys/make_formats.py writes
%
%   Each must read as expected.json says, as Python's test_formats.py checks
%   for the Python readers.

    properties
        Files string
        Expected struct
    end

    methods (TestClassSetup)
        function setUp(testCase)
            testCase.applyFixture(matlab.unittest.fixtures.PathFixture( ...
                fullfile(nansen.internal.repoRoot(), "modules", "ophys", "matlab")));
            testCase.Files = fullfile(nansen.internal.repoRoot(), "conformance", "files", "ophys");
            testCase.Expected = jsondecode(fileread(fullfile(testCase.Files, "expected.json")));
        end
    end

    methods (Test)
        function readsDevRois(testCase)   % Mask, Circle and Polygon ROIs of dev's roimanager
            testCase.verifyDocument(ophys.NansenRoiArray().read(fullfile(testCase.Files, "rois_nansen.mat")), testCase.Expected.nansen);
        end

        function readsDevRoiGroups(testCase)   % two planes, classified, with an IMask ROI: each ROI with its plane
            testCase.verifyDocument(ophys.NansenRoiArray().read(fullfile(testCase.Files, "rois_group.mat")), testCase.Expected.roiGroup);
        end

        function writesDevRoisAsDevReadsThem(testCase)
            folder = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            path = fullfile(folder, "rois.mat");
            document = ophys.NansenRoiArray().read(fullfile(testCase.Files, "rois_group.mat"));
            ophys.NansenRoiArray().write(path, document);
            saved = load(path);
            testCase.verifyTrue(all(isfield(saved, ["roiArray", "roiClassification", "roiImages", "roiStats"])));
            testCase.verifyEqual(size(saved.roiArray), [2, 1]);   % cells of planes x channels
            testCase.verifyEqual(string({saved.roiArray{1}.shape}), ["Mask", "Mask", "Mask"]);
            testCase.verifyEqual(saved.roiClassification{1}, [1; 2; 0]);
            testCase.verifyEqual([saved.PlaneNumber{:}], [1, 2]);
            testCase.verifyDocument(ophys.NansenRoiArray().read(path), testCase.Expected.roiGroup);
            rois = document.rois(1:3);   % ROIs without places: one roiArray
            for k = 1:3
                rois{k} = rmfield(rois{k}, ["plane", "channel"]);
            end
            onePlane = struct("imageSize", document.imageSize, "rois", {rois});
            ophys.NansenRoiArray().write(fullfile(folder, "one.mat"), onePlane);
            saved = load(fullfile(folder, "one.mat"));
            testCase.verifyEqual(string({saved.roiArray.shape}), ["Mask", "Mask", "Mask"]);
            testCase.verifyFalse(isfield(saved, "PlaneNumber"));
        end

        function readsSuite2pBinaries(testCase)
            stack = ophys.Suite2pBinary().open(fullfile(testCase.Files, "suite2p", "plane0", "data.bin"));
            expected = testCase.Expected.suite2pBinary;
            testCase.verifyEqual(size(stack), expected.size');
            testCase.verifyEqual(stack.ClassName, "int16");
            at = expected.pixel.at' + 1;
            frame = stack.frames(at(3), at(3));
            testCase.verifyEqual(double(frame(at(1), at(2))), expected.pixel.value);
            frame = stack.frames(3, 3);
            testCase.verifyEqual(double(frame(9, :))', expected.frame2row8);
            testCase.verifyEqual(sum(double(stack.all()), "all"), expected.sum);
        end

        function readsVideosInColourOrGray(testCase)
            for name = ["rgb", "gray"]
                expected = testCase.Expected.video.(name);
                stack = ophys.VideoFile().open(fullfile(testCase.Files, "video", name + ".avi"));
                testCase.verifyEqual(size(stack), expected.size', name);
                testCase.verifyEqual(stack.ClassName, "uint8", name);
                data = stack.all();
                at = num2cell(expected.pixel.at' + 1);
                testCase.verifyEqual(double(data(at{:})), expected.pixel.value, name);
                testCase.verifyEqual(sum(double(data), "all"), expected.sum, name);
                index = repmat({':'}, 1, ndims(data) - 1);
                testCase.verifyEqual(stack.frames(2, 3), data(index{:}, 2:3), name);   % a chunk reads the same
                testCase.verifyMetadata(stack, expected.metadata, name);
            end
        end

        function readsImageFilesAsFrames(testCase)
            for kind = ["gray", "colour"]
                pattern = "*.png";
                other = "*.bmp";
                if kind == "colour"
                    [pattern, other] = deal(other, pattern);
                end
                listing = dir(fullfile(testCase.Files, "images", pattern));
                paths = flip(string(fullfile({listing.folder}, {listing.name})));   % any order: natural order inside
                expected = testCase.Expected.images.(kind);
                stack = ophys.ImageFiles().open(paths);
                testCase.verifyEqual(size(stack), expected.size', kind);
                data = stack.all();
                at = num2cell(expected.pixel.at' + 1);
                testCase.verifyEqual(double(data(at{:})), expected.pixel.value, kind);
                testCase.verifyEqual(sum(double(data), "all"), expected.sum, kind);
                otherListing = dir(fullfile(testCase.Files, "images", other));
                mixed = ophys.ImageFiles().open([paths(1), string(fullfile({otherListing.folder}, {otherListing.name}))]);
                testCase.verifyError(@() mixed.all(), "nansen:InvalidData", kind);   % frames of different sizes
            end
        end

        function readsThorImageFramesAsChannels(testCase)
            listing = dir(fullfile(testCase.Files, "thorlabs", "*.tif"));
            paths = flip(string(fullfile({listing.folder}, {listing.name})));   % any order: natural order inside
            expected = testCase.Expected.thorlabs;
            stack = ophys.ThorLabsTiffs().open(paths);
            testCase.verifyEqual(size(stack), expected.size');
            data = stack.all();
            at = num2cell(expected.pixel.at' + 1);
            testCase.verifyEqual(double(data(at{:})), expected.pixel.value);
            testCase.verifyEqual(sum(double(data), "all"), expected.sum);
            testCase.verifyEqual(stack.frames(2, 3), data(:, :, :, 2:3));
            testCase.verifyMetadata(stack, expected.metadata, "thorlabs");   % from the Experiment.xml beside the files
            one = ophys.ThorLabsTiffs().open(paths(startsWith(string({listing(end:-1:1).name}), "ChanA")));
            testCase.verifyEqual(one.all(), squeeze(data(:, :, 1, :)));
            testCase.verifyMetadata(one, expected.metadata, "one channel");
        end

        function readsTsmFilesLessTheirDarkFrame(testCase)
            stack = ophys.TsmStack().open(fullfile(testCase.Files, "macroscope.tsm"));
            expected = testCase.Expected.tsm;
            testCase.verifyEqual(size(stack), expected.size');
            testCase.verifyEqual(stack.ClassName, "int16");
            data = stack.all();
            for name = ["pixel", "saturated"]
                at = num2cell(expected.(name).at' + 1);
                testCase.verifyEqual(double(data(at{:})), expected.(name).value, name);
            end
            testCase.verifyEqual(sum(double(data), "all"), expected.sum);
            testCase.verifyEqual(stack.frames(2, 3), data(:, :, 2:3));
            testCase.verifyMetadata(stack, expected.metadata, "tsm");   % 1 / EXPOSURE
        end

        function readsAndWritesDevBinaryStacks(testCase)
            raw = fullfile(testCase.Files, "binary", "stack.raw");
            stack = ophys.BinaryStack().open(raw);
            expected = testCase.Expected.devBinary;
            testCase.verifyEqual(size(stack), expected.size');
            testCase.verifyEqual(stack.ClassName, "uint16");
            at = expected.pixel.at' + 1;
            frame = stack.frames(at(3), at(3));
            testCase.verifyEqual(double(frame(at(1), at(2))), expected.pixel.value);
            frame = stack.frames(3, 3);
            testCase.verifyEqual(double(frame(9, :))', expected.frame2row8);
            data = stack.all();
            testCase.verifyEqual(sum(double(data), "all"), expected.sum);
            testCase.verifyMetadata(stack, expected.metadata, "devBinary");
            folder = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            ophys.BinaryStack().write(fullfile(folder, "out.raw"), data);
            testCase.verifyEqual(splitlines(strtrim(string(fileread(fullfile(folder, "out.ini"))))), ["Size = 9  7  5"; "Class = uint16"]);
            testCase.verifyEqual(readBytes(fullfile(folder, "out.raw")), readBytes(raw));   % as dev wrote it
            writer = ophys.BinaryStack().create(fullfile(folder, "made.raw"), [9, 7, 5], "uint16");
            writer.write(1, data(:, :, 1:2));
            writer.write(3, data(:, :, 3:5));
            writer.close();
            testCase.verifyEqual(readBytes(fullfile(folder, "made.raw")), readBytes(raw));
        end

        function readsSuite2pCells(testCase)   % those suite2p left out rejected
            testCase.verifyDocument(ophys.Suite2pRois().read(fullfile(testCase.Files, "Fall.mat")), testCase.Expected.suite2p);
        end

        function readsCaimanComponents(testCase)
            testCase.verifyDocument(ophys.CaimanRois().read(fullfile(testCase.Files, "caiman.hdf5")), testCase.Expected.caiman);
        end

        function readsExtractCells(testCase)
            testCase.verifyDocument(ophys.ExtractRois().read(fullfile(testCase.Files, "extract.mat")), testCase.Expected.extract);
        end

        function readsAPrairieTSeriesAFrameAtATime(testCase)
            stack = ophys.PrairieTSeries().open(fullfile(testCase.Files, "tseries", "TSeries-001.xml"));
            expected = testCase.Expected.prairie;
            testCase.verifyEqual(size(stack), expected.size');
            at = expected.pixel.at' + 1;
            volume = stack.frames(at(4), at(4));
            testCase.verifyEqual(double(volume(at(1), at(2), at(3))), expected.pixel.value);
            frame = stack.frames(3, 3);
            testCase.verifyEqual(double(frame(:, :, 2)), expected.channel2frame3);
            testCase.verifyEqual(sum(double(stack.all()), "all"), expected.sum);
            testCase.verifyMetadata(stack, expected.metadata, "prairie");   % 1 / framePeriod and micronsPerPixel
        end

        function readsAndWritesHdf5Stacks(testCase)
            stack = ophys.Hdf5Stack().open(fullfile(testCase.Files, "stack.h5"));
            expected = testCase.Expected.hdf5;
            testCase.verifyEqual(size(stack), expected.size');
            at = expected.pixel.at' + 1;
            frame = stack.frames(at(3), at(3));
            testCase.verifyEqual(double(frame(at(1), at(2))), expected.pixel.value);
            frame = stack.frames(7, 7);
            testCase.verifyEqual(double(frame(3, :))', expected.frame6row2);
            testCase.verifyMetadata(stack, expected.metadata, "hdf5");
            folder = testCase.applyFixture(matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            data = uint16(reshape(0:59, 3, 4, 5));
            ophys.Hdf5Stack().write(fullfile(folder, "out.h5"), data);
            testCase.verifyEqual(ophys.Hdf5Stack().read(fullfile(folder, "out.h5")), data);
        end

        function readsTheMetadataOfScanImageFiles(testCase)
            files = ["scanimage.tif", "scanimage_planes.tif"];
            keys = ["scanimage", "scanimagePlanes"];
            for i = 1:2
                expected = testCase.Expected.(keys(i));
                stack = ophys.ScanImageTiff().open(fullfile(testCase.Files, files(i)));
                testCase.verifyEqual(size(stack), expected.size', keys(i));
                testCase.verifyEqual(sum(double(stack.all()), "all"), expected.sum, keys(i));
                testCase.verifyMetadata(stack, expected.metadata, keys(i));
            end
            testCase.verifyMetadata(stack.select(3, 1), expected.metadata, "a channel of it");
        end

        function readsTheMetadataOfASciScanZStack(testCase)
            expected = testCase.Expected.sciscan;
            raw = fullfile(testCase.Files, "sciscan", "zstack.raw");
            stacks = {ophys.SciScanRaw().open(raw), ophys.BinaryStack().open(raw)};   % dev's binary stack reads it as SciScan's
            for i = 1:2
                testCase.verifyEqual(size(stacks{i}), expected.size');
                testCase.verifyEqual(sum(double(stacks{i}.all()), "all"), expected.sum);
                testCase.verifyMetadata(stacks{i}, expected.metadata, "sciscan");
            end
        end

        function loadsTheVersion73File(testCase)   % made by h5py as MATLAB makes them; Python reads it too
            data = load(fullfile(testCase.Files, "v73.mat"));
            expected = testCase.Expected.mat73;
            testCase.verifyEqual(data.matrix, expected.matrix);
            testCase.verifyEqual(string(data.name), string(expected.name));
            testCase.verifyEqual(data.flags, expected.flags');
            testCase.verifyEqual(data.info.rate, expected.rate);
        end

        function refusesOtherFiles(testCase)
            testCase.verifyError(@() ophys.Suite2pRois().read(fullfile(testCase.Files, "extract.mat")), "nansen:InvalidData");
            testCase.verifyError(@() ophys.ExtractRois().read(fullfile(testCase.Files, "Fall.mat")), "nansen:InvalidData");
            testCase.verifyError(@() ophys.NansenRoiArray().read(fullfile(testCase.Files, "Fall.mat")), "nansen:InvalidData");
        end
    end

    methods (Access = private)
        function verifyMetadata(testCase, stack, expected, name)
            % compared as JSON, as data.frame sends it
            testCase.verifyEqual(jsondecode(jsonencode(stack.Metadata)), expected, name);
        end

        function verifyDocument(testCase, actual, expected)
            % compared as JSON: the document as the API would send it
            testCase.verifyEqual(jsondecode(jsonencode(actual)), expected);
        end
    end
end

function bytes = readBytes(path)
    fid = fopen(path, "r");
    closer = onCleanup(@() fclose(fid));
    bytes = fread(fid, Inf, "*uint8");
end
