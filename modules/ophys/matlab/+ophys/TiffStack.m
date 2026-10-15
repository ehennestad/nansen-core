classdef TiffStack < nansen.FileAdapter
%TiffStack A multi-page TIFF file, as height x width x frames
%
%   Pages of several samples (RGB, or grayscale with extra samples;
%   contiguous or planar) are channels: height x width x samples x frames,
%   as dev's TiffMultiPart reads them (its multisample channel mode). A
%   recording split into a file series per channel (dev's
%   TiffMultiPartMultiChannel: rec_ch1_part_001.tif, rec_ch2_part_001.tif,
%   ...) is height x width x channels x frames: when every file's name has
%   a channel number (channelNumber) and there are at least two, the files
%   of each channel are its frames, joined in natural order, and the
%   channels come in the order of their numbers. Otherwise every file is a
%   part of one recording, joined along the frames in natural order.
%
%   Written as one page per frame, uncompressed, with the data's class
%   (integers of 8 to 32 bits, single or double); BigTIFF when it would
%   pass 4 GB. Python's ophys_adapters.TiffStack reads and writes the same
%   files with tifffile.

    methods
        function data = read(obj, path)
            data = all(obj.open(path));
        end

        function stack = open(~, paths)
            %open The pages of the files, in natural order, as one nansen.Stack read page by page; files per channel as channels
            paths = nansen.internal.naturalOrder(paths);
            groups = ophys.TiffStack.channelGroups(paths);
            if isempty(groups)
                stack = ophys.TiffStack.series(paths, true);
                return
            end
            channels = cell(1, numel(groups));
            for k = 1:numel(groups)
                channels{k} = ophys.TiffStack.series(groups{k}, false);
            end
            first = channels{1};
            for k = 2:numel(channels)
                if ~isequal(channels{k}.Size, first.Size) || channels{k}.ClassName ~= first.ClassName
                    nansen.internal.throwError("invalid-data", "the channels of the recording differ in size, frames or type: %s %s and %s %s", ...
                        mat2str(first.Size), first.ClassName, mat2str(channels{k}.Size), channels{k}.ClassName)
                end
            end
            stack = nansen.Stack([first.Size(1:2), numel(channels), first.Size(3)], first.ClassName, ...
                @(a, b) ophys.TiffStack.together(channels, a, b));
        end

        function write(obj, path, data)
            if ndims(data) > 3
                nansen.internal.throwError("invalid-params", "a TIFF stack is height x width x frames of integers or floats")
            end
            writer = obj.create(path, size(data, 1:3), class(data));
            closer = onCleanup(@() writer.close());
            writer.write(1, data);
        end

        function writer = create(~, path, dimensions, className)
            %create A writer of a new TIFF stack, a chunk of frames at a time, each frame a page; frames come in order
            writer = ophys.internal.TiffPageWriter(path, dimensions, className);
        end
    end

    methods (Static)
        function number = channelNumber(name)
            %channelNumber The channel number in a TIFF file's name, or NaN
            %
            %   ch1, chan1, channel1 (any case, _ or - before the number
            %   allowed: ch_1), not after a letter or digit; else C1 followed
            %   by -, _ or . (as ImageJ names a stack's channels: C1-rec.tif).
            %   The first match counts. Python's ophys_adapters.tiff_channel
            %   uses the same patterns.
            token = regexp(char(name), '(?<![A-Za-z0-9])(?:ch|chan|channel)[_-]?(\d+)(?!\d)', "tokens", "once", "ignorecase");
            if isempty(token)
                token = regexp(char(name), '(?<![A-Za-z0-9])C(\d+)(?=[-_.])', "tokens", "once");
            end
            if isempty(token)
                number = NaN;
            else
                number = str2double(token{1});
            end
        end

        function groups = channelGroups(paths)
            %channelGroups The paths of each channel (a cell array), in the order of the channel numbers
            %
            %   When there are several files, each with a channel number in
            %   its name, and at least two channels; {} otherwise (one
            %   recording in parts).
            groups = {};
            paths = reshape(string(paths), 1, []);
            if numel(paths) < 2
                return
            end
            numbers = zeros(1, numel(paths));
            for i = 1:numel(paths)
                [~, name, ext] = fileparts(paths(i));
                numbers(i) = ophys.TiffStack.channelNumber(name + ext);
            end
            if any(isnan(numbers))
                return
            end
            channels = unique(numbers);   % sorted
            if numel(channels) < 2
                return
            end
            groups = cell(1, numel(channels));
            for k = 1:numel(channels)
                groups{k} = paths(numbers == channels(k));
            end
        end

        function stack = series(paths, samples)
            %series The pages of TIFF files one after another, as height x width x frames, or height x width x samples x frames
            %
            %   Pages of several samples are refused unless samples is true.
            [count, reader, first] = ophys.internal.tiffPages(paths, samples);
            stack = nansen.Stack([size(first.Page), count], class(first.Page), reader);
        end

        function data = together(channels, first, last)
            %together Frames first..last of every channel, as height x width x channels x frames
            parts = cellfun(@(c) permute(c.frames(first, last), [1, 2, 4, 3]), channels, UniformOutput=false);
            data = cat(3, parts{:});
        end
    end
end
