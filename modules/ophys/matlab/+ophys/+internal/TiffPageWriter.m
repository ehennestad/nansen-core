classdef TiffPageWriter < handle
%TiffPageWriter Writes a height x width x frames stack to a TIFF file a chunk of frames at a time
%
%   writer.write(first, chunk) puts frames first..first+n-1 (1-based), each
%   a page; frames come in order. writer.close() finishes the file. As
%   nansen.StackWriter for other files; BigTIFF when it would pass 4 GB.
%   Python's ophys_adapters.TiffPageWriter is the same.

    properties (SetAccess = private)
        Size (1, 3) double
        ClassName (1, 1) string
        Written (1, 1) double = 0
    end

    properties (Access = private)
        File = []
        Tags struct
    end

    methods
        function obj = TiffPageWriter(path, dimensions, className)
            formats = struct("uint8", "UInt", "uint16", "UInt", "uint32", "UInt", "int8", "Int", "int16", "Int", ...
                "int32", "Int", "single", "IEEEFP", "double", "IEEEFP");
            className = string(className);
            if ~isfield(formats, className) || numel(dimensions) > 3
                nansen.internal.throwError("invalid-params", "a TIFF stack is height x width x frames of integers or floats")
            end
            obj.Size = [dimensions, ones(1, 3 - numel(dimensions))];
            obj.ClassName = className;
            bits = 8 * nansen.StackWriter.bytesOf(className);
            mode = "w";
            if prod(obj.Size) * bits / 8 > 4e9
                mode = "w8";
            end
            obj.Tags = struct("ImageLength", obj.Size(1), "ImageWidth", obj.Size(2), ...
                "Photometric", Tiff.Photometric.MinIsBlack, "BitsPerSample", bits, ...
                "SamplesPerPixel", 1, "SampleFormat", Tiff.SampleFormat.(formats.(className)), ...
                "PlanarConfiguration", Tiff.PlanarConfiguration.Chunky, "Compression", Tiff.Compression.None, ...
                "RowsPerStrip", obj.Size(1));
            obj.File = Tiff(char(path), char(mode));
        end

        function write(obj, first, chunk)
            %write Frames first..first+n-1 of the stack (1-based), right after those written before
            n = size(chunk, 3);
            if isempty(obj.File) || first ~= obj.Written + 1 || size(chunk, 1) ~= obj.Size(1) ...
                    || size(chunk, 2) ~= obj.Size(2) || obj.Written + n > obj.Size(3)
                nansen.internal.throwError("invalid-params", "a %s chunk at frame %d does not follow the %d frames of a %s TIFF stack", ...
                    mat2str(size(chunk)), first, obj.Written, mat2str(obj.Size))
            end
            chunk = cast(chunk, char(obj.ClassName));
            for t = 1:n
                if obj.Written > 0
                    obj.File.writeDirectory();
                end
                obj.File.setTag(obj.Tags);
                obj.File.write(chunk(:, :, t));
                obj.Written = obj.Written + 1;
            end
        end

        function close(obj)
            if ~isempty(obj.File)
                close(obj.File);
                obj.File = [];
            end
        end

        function delete(obj)
            obj.close();
        end
    end
end
