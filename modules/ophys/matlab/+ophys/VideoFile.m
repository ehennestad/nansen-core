classdef VideoFile < nansen.FileAdapter
%VideoFile A video file, as dev's Video stack reads one, with VideoReader
%
%   uint8 frames, height x width x frames, or height x width x 3 x frames
%   (red, green, blue as channels) when it has colour. A video whose first
%   frame has the same red, green and blue is read as grayscale, so the two
%   languages' decoders agree. Read a chunk of frames at a time; read only.
%   Its Metadata's frameRate is the video's. Python's
%   ophys_adapters.VideoFile reads the same with imageio.

    methods
        function data = read(obj, path)
            data = all(obj.open(path));
        end

        function stack = open(~, paths)
            paths = nansen.internal.naturalOrder(paths);
            parts = cell(1, numel(paths));
            for i = 1:numel(paths)
                video = VideoReader(paths(i));
                count = video.NumFrames;
                first = read(video, 1);
                gray = size(first, 3) == 1 || (isequal(first(:, :, 1), first(:, :, 2)) && isequal(first(:, :, 2), first(:, :, 3)));
                if gray
                    dimensions = [size(first, 1), size(first, 2), count];
                else
                    dimensions = [size(first, 1), size(first, 2), 3, count];
                end
                path = paths(i);
                parts{i} = nansen.Stack(dimensions, "uint8", @(a, b) ophys.VideoFile.frames(path, a, b, gray));
                parts{i}.Metadata = ophys.internal.stackMetadata(video.FrameRate);
            end
            stack = nansen.Stack.join(parts);
        end

        function write(~, ~, ~)
            nansen.internal.throwError("invalid-params", "video files are read only; save stacks as TIFF or another format")
        end
    end

    methods (Static)
        function data = frames(path, first, last, gray)
            %frames Frames first..last (1-based): height x width x count, or x 3 x count with colour
            video = VideoReader(path);
            data = uint8(read(video, [first, last]));   % height x width x channels x count
            if gray
                data = reshape(data(:, :, 1, :), size(data, 1), size(data, 2), []);
            end
        end
    end
end
