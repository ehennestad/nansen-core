classdef ScanImageTiff < nansen.FileAdapter
%ScanImageTiff A ScanImage TIFF file: frames of every saved channel, plane after plane, volume after volume
%
%   The channels (SI.hChannels.channelSave) and planes
%   (SI.hStackManager.numSlices) are read from the first page's Software
%   tag, or its ImageDescription for older versions. Reads height x width x
%   frames, height x width x channels x frames with more than one channel,
%   and height x width x channels x planes x frames with more than one
%   plane. A multi-ROI recording (SI.hRoiManager.mroiEnable) has its ROIs
%   one above the other on each page, with flyback lines between them, and
%   their sizes in the Artist tag: the ROIs are put side by side, padded
%   with 0 at the bottom to the tallest. Pages after the last whole volume
%   are left out. Its Metadata is read from the same text (metadata).
%   Python's ophys_adapters.ScanImageTiff reads the same.

    methods
        function data = read(obj, path)
            data = all(obj.open(path));
        end

        function stack = open(~, paths)
            %open The recording as a nansen.Stack read volume by volume; ScanImage's files of one recording are
            %joined, their pages one sequence (a volume may begin in one file and end in the next)
            paths = nansen.internal.naturalOrder(paths);
            [count, reader, first] = ophys.internal.tiffPages(paths);
            text = first.Software + newline + first.ImageDescription;
            if ~contains(text, "SI.")
                nansen.internal.throwError("invalid-data", "%s is not a ScanImage TIFF file (no SI. metadata)", paths(1))
            end
            channels = max(1, numel(ophys.ScanImageTiff.siNumbers(text, "hChannels.channelSave")));
            planes = ophys.ScanImageTiff.siNumbers(text, "hStackManager.actualNumSlices");
            if isempty(planes)
                planes = ophys.ScanImageTiff.siNumbers(text, "hStackManager.numSlices");
            end
            if isempty(planes)
                planes = 1;
            end
            planes = planes(1);
            mroi = ophys.ScanImageTiff.siNumbers(text, "hRoiManager.mroiEnable");
            mosaic = ~isempty(mroi) && mroi(1) ~= 0 && strlength(first.Artist) > 0;
            volumes = floor(count / (channels * planes));   % pages after the last whole volume are left out
            read = @(a, b) ophys.ScanImageTiff.volumes(reader, size(first.Page), channels, planes, mosaic, first.Artist, paths(1), a, b);
            if volumes > 0
                probe = read(1, 1);
            else
                probe = zeros([size(first.Page), 0], "like", first.Page);
            end
            dimensions = size(probe, 1:2);
            if planes > 1
                dimensions = [dimensions, channels, planes];
            elseif channels > 1
                dimensions = [dimensions, channels];
            end
            stack = nansen.Stack([dimensions, volumes], class(first.Page), read);
            stack.Metadata = ophys.ScanImageTiff.metadata(text, first.Artist, planes, mosaic);
        end

        function write(~, ~, ~)
            nansen.internal.throwError("invalid-params", "ScanImage files are written by ScanImage; save a stack with npy or ophys.tiff_stack")
        end
    end

    methods (Static)
        function numbers = siNumbers(text, name)
            %siNumbers The numbers of the SI.<name> = value line of ScanImage metadata (true is 1, false 0); [] if there is none
            tokens = regexp(char(text), "(?:^|\n)\s*(?:scanimage\.)?SI\." + regexptranslate("escape", name) + "\s*=\s*([^\n]*)", "tokens", "once");
            numbers = [];
            if isempty(tokens)
                return
            end
            value = replace(string(tokens{1}), ["true", "false"], ["1", "0"]);
            numbers = str2double(regexp(value, "-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?", "match"));
        end

        function metadata = metadata(text, artist, planes, mosaic)
            %metadata A ScanImage recording's frameRate, pixelSize and zStep, as Python's ophys_adapters.scanimage_metadata
            %
            %   frameRate: SI.hRoiManager.scanVolumeRate, else scanFrameRate
            %   when it has one plane. zStep, with more than one plane:
            %   SI.hStackManager.actualStackZStepSize, else stackZStepSize.
            %   pixelSize: the extent of the corners SI.hRoiManager.imagingFovUm
            %   (or imagingFovDeg times SI.objectiveResolution, µm per degree)
            %   over pixelsPerLine and linesPerFrame; for a multi-ROI recording,
            %   the first ROI's scanfield sizeXY (degrees) times
            %   SI.objectiveResolution over its pixelResolutionXY.
            rate = ophys.ScanImageTiff.firstNumber(text, "hRoiManager.scanVolumeRate");
            if isempty(rate) && planes == 1
                rate = ophys.ScanImageTiff.firstNumber(text, "hRoiManager.scanFrameRate");
            end
            step = [];
            if planes > 1
                step = ophys.ScanImageTiff.firstNumber(text, "hStackManager.actualStackZStepSize");
                if isempty(step)
                    step = ophys.ScanImageTiff.firstNumber(text, "hStackManager.stackZStepSize");
                end
            end
            resolution = ophys.ScanImageTiff.firstNumber(text, "objectiveResolution");
            pixelSize = [];
            if mosaic
                rois = jsondecode(char(artist)).RoiGroups.imagingRoiGroup.rois;
                if iscell(rois)
                    roi = rois{1};
                else
                    roi = rois(1);
                end
                field = roi.scanfields;
                if iscell(field)
                    field = field{1};
                end
                field = field(1);
                if ~isempty(resolution) && isfield(field, "sizeXY")
                    pixelSize = reshape(double(field.sizeXY), 1, 2) * resolution ./ reshape(double(field.pixelResolutionXY), 1, 2);
                end
            else
                corners = ophys.ScanImageTiff.siNumbers(text, "hRoiManager.imagingFovUm");
                if isempty(corners) && ~isempty(resolution)
                    corners = ophys.ScanImageTiff.siNumbers(text, "hRoiManager.imagingFovDeg") * resolution;
                end
                pixels = ophys.ScanImageTiff.firstNumber(text, "hRoiManager.pixelsPerLine");
                lines = ophys.ScanImageTiff.firstNumber(text, "hRoiManager.linesPerFrame");
                if numel(corners) >= 4 && mod(numel(corners), 2) == 0 && ~isempty(pixels) && ~isempty(lines) && pixels ~= 0 && lines ~= 0
                    xs = corners(1:2:end);
                    ys = corners(2:2:end);
                    pixelSize = [(max(xs) - min(xs)) / pixels, (max(ys) - min(ys)) / lines];
                end
            end
            metadata = ophys.internal.stackMetadata(rate, pixelSize, abs(step));
        end

        function value = firstNumber(text, name)
            %firstNumber The first number of the SI.<name> line; [] if there is none
            value = ophys.ScanImageTiff.siNumbers(text, name);
            if ~isempty(value)
                value = value(1);
            end
        end

        function out = mosaic(data, artist, path)
            %mosaic The ROIs of a multi-ROI recording side by side: ROI k is rows sum(h_1..h_(k-1)) + k-1 flyback gaps on
            try
                rois = jsondecode(char(artist)).RoiGroups.imagingRoiGroup.rois;
            catch
                nansen.internal.throwError("invalid-data", "%s has no multi-ROI layout in its Artist tag", path)
            end
            if isstruct(rois)
                rois = num2cell(rois);
            end
            sizes = zeros(numel(rois), 2);   % [width, height]
            for k = 1:numel(rois)
                field = rois{k}.scanfields;
                if iscell(field)
                    field = field{1};
                end
                sizes(k, :) = reshape(double(field(1).pixelResolutionXY), 1, 2);
            end
            sizes(:, 1) = min(sizes(:, 1), size(data, 2));
            gap = 0;
            if numel(rois) > 1
                gap = floor((size(data, 1) - sum(sizes(:, 2))) / (numel(rois) - 1));
            end
            rest = size(data, 3:5);
            out = zeros([max(sizes(:, 2)), sum(sizes(:, 1)), rest], "like", data);
            top = 0;
            left = 0;
            for k = 1:numel(rois)
                w = sizes(k, 1);
                h = sizes(k, 2);
                out(1:h, left + 1:left + w, :, :, :) = data(top + 1:top + h, 1:w, :, :, :);
                top = top + h + gap;
                left = left + w;
            end
        end
    end

    methods (Static, Access = private)
        function data = volumes(reader, pageSize, channels, planes, mosaic, artist, path, a, b)
            %volumes Volumes a..b as height x width (x channels (x planes)) x n
            count = b - a + 1;
            pages = reader((a - 1) * channels * planes + 1, b * channels * planes);
            data = reshape(pages, pageSize(1), pageSize(2), channels, planes, count);
            if mosaic
                data = ophys.ScanImageTiff.mosaic(data, artist, path);
            end
            if planes == 1
                data = reshape(data, size(data, 1), size(data, 2), channels, count);
                if channels == 1
                    data = reshape(data, size(data, 1), size(data, 2), count);
                end
            end
        end
    end
end
