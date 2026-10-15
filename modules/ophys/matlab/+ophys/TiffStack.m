classdef TiffStack < nansen.FileAdapter
%TiffStack A multi-page grayscale TIFF file, as height x width x frames
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
            %open The pages of the files, in natural order, as one nansen.Stack read page by page
            [count, reader, first] = ophys.internal.tiffPages(nansen.internal.naturalOrder(paths));
            stack = nansen.Stack([size(first.Page), count], class(first.Page), reader);
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
end
