classdef TiffStack < nansen.FileAdapter
%TiffStack A multi-page grayscale TIFF file, as height x width x frames
%
%   Written as one page per frame, uncompressed, with the data's class
%   (integers of 8 to 32 bits, single or double); BigTIFF when it would
%   pass 4 GB. Python's ophys_adapters.TiffStack reads and writes the same
%   files with tifffile.

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
            frames = {};
            while true
                frames{end + 1} = file.read(); %#ok<AGROW>
                if file.lastDirectory()
                    break
                end
                file.nextDirectory();
            end
            if ~ismatrix(frames{1})
                nansen.internal.throwError("invalid-data", "%s does not hold grayscale frames", path)
            end
            data = cat(3, frames{:});
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
