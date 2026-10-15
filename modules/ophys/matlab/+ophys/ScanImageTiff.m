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
%   are left out. Python's ophys_adapters.ScanImageTiff reads the same.

    methods
        function data = read(~, path)
            warning("off", "imageio:tiffmexutils:libtiffWarning");
            warning("off", "MATLAB:imagesci:tiffmexutils:libtiffWarning");
            try
                file = Tiff(char(path), "r");
            catch error
                nansen.internal.throwError("invalid-data", "%s is not a TIFF file: %s", path, error.message)
            end
            closer = onCleanup(@() close(file));
            text = ophys.ScanImageTiff.tag(file, "Software") + newline + ophys.ScanImageTiff.tag(file, "ImageDescription");
            artist = ophys.ScanImageTiff.tag(file, "Artist");
            pages = {};
            while true
                pages{end + 1} = file.read(); %#ok<AGROW>
                if file.lastDirectory()
                    break
                end
                file.nextDirectory();
            end
            if ~contains(text, "SI.")
                nansen.internal.throwError("invalid-data", "%s is not a ScanImage TIFF file (no SI. metadata)", path)
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
            stack = cat(3, pages{:});
            volumes = floor(size(stack, 3) / (channels * planes));
            data = reshape(stack(:, :, 1:volumes * channels * planes), size(stack, 1), size(stack, 2), channels, planes, volumes);
            mroi = ophys.ScanImageTiff.siNumbers(text, "hRoiManager.mroiEnable");
            if ~isempty(mroi) && mroi(1) ~= 0 && strlength(artist) > 0
                data = ophys.ScanImageTiff.mosaic(data, artist, path);
            end
            if planes == 1
                data = reshape(data, size(data, 1), size(data, 2), channels, volumes);
                if channels == 1
                    data = reshape(data, size(data, 1), size(data, 2), volumes);
                end
            end
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
        function value = tag(file, name)
            try
                value = string(file.getTag(char(name)));
            catch
                value = "";
            end
        end
    end
end
