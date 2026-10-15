classdef ImageFiles < nansen.FileAdapter
%ImageFiles A sequence of image files (PNG, JPEG, BMP, ...), one frame per file in natural order
%
%   As dev's virtual Image stack, matched by a file pattern with
%   cardinality many. Grayscale images are height x width x frames, colour
%   ones height x width x 3 x frames (RGB; an alpha channel is left out,
%   and indexed images are their colours). Read a chunk at a time; read
%   only. Python's ophys_adapters.ImageFiles reads the same.

    methods
        function data = read(obj, path)
            data = all(obj.open(path));
        end

        function stack = open(~, paths)
            paths = nansen.internal.naturalOrder(string(paths));
            first = ophys.ImageFiles.image(paths(1));
            dimensions = size(first);
            if ndims(first) == 2
                dimensions = dimensions(1:2);
            end
            stack = nansen.Stack([dimensions, numel(paths)], class(first), @(a, b) ophys.ImageFiles.frames(paths, first, a, b));
        end

        function write(~, ~, ~)
            nansen.internal.throwError("invalid-params", "image files are read as a stack; save stacks as TIFF")
        end
    end

    methods (Static, Access = private)
        function data = frames(paths, first, a, b)
            % Files a..b as frames along the last dimension
            parts = cell(1, b - a + 1);
            for t = a:b
                image = ophys.ImageFiles.image(paths(t));
                if ~isequal(size(image), size(first)) || ~strcmp(class(image), class(first))
                    [~, name, ext] = fileparts(paths(t));
                    nansen.internal.throwError("invalid-data", "%s differs in size or type from the first image", name + ext)
                end
                parts{t - a + 1} = image;
            end
            data = cat(ndims(first) + 1, parts{:});
        end

        function image = image(path)
            % An image file as height x width (grayscale) or height x width x 3 (RGB)
            [image, map] = imread(path);
            if ~isempty(map)   % indexed: its colours
                image = uint8(round(255 * ind2rgb(image, map)));
            end
            if size(image, 3) > 3
                image = image(:, :, 1:3);   % an alpha channel left out
            end
        end
    end
end
