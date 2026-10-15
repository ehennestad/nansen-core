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

        function write(~, path, data)
            formats = struct("uint8", "UInt", "uint16", "UInt", "uint32", "UInt", "int8", "Int", "int16", "Int", ...
                "int32", "Int", "single", "IEEEFP", "double", "IEEEFP");
            if ~isfield(formats, class(data)) || ndims(data) > 3
                nansen.internal.throwError("invalid-params", "a TIFF stack is height x width x frames of integers or floats")
            end
            info = whos("data");
            mode = "w";
            if info.bytes > 4e9
                mode = "w8";
            end
            file = Tiff(char(path), char(mode));
            closer = onCleanup(@() close(file));
            [height, width, frames] = size(data);
            tags = struct("ImageLength", height, "ImageWidth", width, ...
                "Photometric", Tiff.Photometric.MinIsBlack, "BitsPerSample", info.bytes / numel(data) * 8, ...
                "SamplesPerPixel", 1, "SampleFormat", Tiff.SampleFormat.(formats.(class(data))), ...
                "PlanarConfiguration", Tiff.PlanarConfiguration.Chunky, "Compression", Tiff.Compression.None, ...
                "RowsPerStrip", height);
            for t = 1:frames
                file.setTag(tags);
                file.write(data(:, :, t));
                if t < frames
                    file.writeDirectory();
                end
            end
        end
    end
end
