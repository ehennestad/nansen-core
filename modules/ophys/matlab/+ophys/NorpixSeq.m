classdef NorpixSeq < nansen.FileAdapter
%NorpixSeq A Norpix StreamPix sequence (.seq), as dev's Sequence stack
%
%   A 1024-byte header (0xFEED, then width, height, bit depth, image size,
%   image format and frame count as uint32 from byte 548, and the frame
%   rate as a double at 584), then the frames, each trueImageSize bytes
%   apart (the image, its timestamp and padding). Raw images only (image
%   format 100, grayscale of 8 or 16 bits, or 200, BGR of 8 bits): height x
%   width x frames, or height x width x 3 x frames in RGB order; an
%   incomplete last frame is left out. Read a chunk at a time; read only.
%   Python's ophys_adapters.NorpixSeq is the same.

    methods
        function data = read(obj, path)
            data = all(obj.open(path));
        end

        function stack = open(~, paths)
            paths = nansen.internal.naturalOrder(paths);
            parts = cell(1, numel(paths));
            for i = 1:numel(paths)
                path = paths(i);
                h = ophys.NorpixSeq.header(path);
                if ~ismember([h.format, h.depth], [100, 8; 100, 16; 200, 24], "rows")
                    nansen.internal.throwError("invalid-data", "%s has image format %d of %d bits; raw grayscale (100) of 8 or " + ...
                        "16 bits and raw BGR (200) of 24 are read", path, h.format, h.depth)
                end
                colours = 1 + 2 * (h.format == 200);
                className = "uint8";
                if h.depth == 16
                    className = "uint16";
                end
                bytes = 1 + (className == "uint16");
                if h.size ~= h.width * h.height * colours * bytes || h.trueSize < h.size
                    nansen.internal.throwError("invalid-data", "%s: an image of %d bytes in %d does not fit %d x %d", ...
                        path, h.size, h.trueSize, h.height, h.width)
                end
                listing = dir(path);
                available = floor((listing.bytes - 1024 + h.trueSize - h.size) / h.trueSize);
                frames = min(h.frames, available);   % an incomplete last frame is left out
                dimensions = [h.height, h.width, frames];
                if colours == 3
                    dimensions = [h.height, h.width, 3, frames];
                end
                parts{i} = nansen.Stack(dimensions, className, @(a, b) ophys.NorpixSeq.frames(path, h, colours, className, a, b));
                parts{i}.Metadata = ophys.internal.stackMetadata(h.rate);
            end
            stack = nansen.Stack.join(parts);
        end

        function write(~, ~, ~)
            nansen.internal.throwError("invalid-params", "Norpix sequences are written by StreamPix; save stacks as TIFF")
        end
    end

    methods (Static)
        function h = header(path)
            %header width, height, depth, size, format, frames, trueSize and rate of a sequence's header
            fid = fopen(path, "r", "l");
            if fid < 0
                nansen.internal.throwError("cannot-open", "cannot open %s", path)
            end
            closer = onCleanup(@() fclose(fid));
            magic = fread(fid, 1, "uint32");
            fseek(fid, 548, "bof");
            values = fread(fid, 9, "uint32");
            rate = fread(fid, 1, "float64");
            if isempty(magic) || magic ~= hex2dec("FEED") || numel(values) < 9 || isempty(rate)
                nansen.internal.throwError("invalid-data", "%s is not a Norpix sequence (no 0xFEED header)", path)
            end
            h = struct("width", values(1), "height", values(2), "depth", values(3), "size", values(5), ...
                "format", values(6), "frames", values(7), "trueSize", values(9), "rate", rate);
        end
    end

    methods (Static, Access = private)
        function data = frames(path, h, colours, className, first, last)
            % Frames first..last, as height x width (x 3) x frames
            fid = fopen(path, "r", "l");
            closer = onCleanup(@() fclose(fid));
            count = last - first + 1;
            data = zeros(h.height, h.width, colours, count, className);
            for t = first:last
                fseek(fid, 1024 + (t - 1) * h.trueSize, "bof");
                values = fread(fid, h.width * h.height * colours, char("*" + className));
                % row-major, the colours of a pixel together: colours x width x height in MATLAB's order
                image = permute(reshape(values, colours, h.width, h.height), [3, 2, 1]);
                if colours == 3
                    image = image(:, :, [3, 2, 1]);   % BGR to RGB
                end
                data(:, :, :, t - first + 1) = image;
            end
            if colours == 1
                data = reshape(data, h.height, h.width, count);
            end
        end
    end
end
