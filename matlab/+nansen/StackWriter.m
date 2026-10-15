classdef StackWriter < handle
%StackWriter Writes a stack of a known size a chunk of frames at a time
%
%   writer.write(first, chunk) puts frames first..first+n-1 (1-based);
%   writer.close() finishes the file. A writer made by an adapter's create
%   (npy) writes each chunk to the file as it comes, frames kept together;
%   any other keeps the stack in memory and calls its finish function with
%   it on close (an adapter's write). A writer to no file writes nothing.
%   Frames never written are 0. Python's nansen.stacks.StackWriter is the same.

    properties (SetAccess = private)
        Size (1, :) double
        ClassName (1, 1) string
        Written (1, 1) double = 0
        Closed (1, 1) logical = false
    end

    properties (Access = private)
        Mode (1, 1) string = "none"   % "file", "memory" or "none"
        Data
        Finish
        Fid = -1
        DataOffset (1, 1) double = 0
        NextFrame (1, 1) double = 1   % the file holds frames 1..NextFrame-1
        Path (1, 1) string = ""
    end

    methods
        function obj = StackWriter(dimensions, className, options)
            arguments
                dimensions (1, :) double
                className (1, 1) string
                options.Finish = []
                options.Path (1, 1) string = ""
                options.Header (1, :) uint8 = uint8([])
            end
            obj.Size = dimensions;
            obj.ClassName = className;
            if strlength(options.Path) > 0
                obj.Mode = "file";
                obj.Path = options.Path;
                obj.Fid = fopen(options.Path, "w", "ieee-le");
                if obj.Fid < 0
                    nansen.internal.throwError("cannot-open", "cannot write %s", options.Path)
                end
                fwrite(obj.Fid, options.Header, "uint8");
                obj.DataOffset = numel(options.Header);
            elseif ~isempty(options.Finish)
                obj.Mode = "memory";
                obj.Finish = options.Finish;
                if className == "logical"
                    obj.Data = false(dimensions);
                else
                    obj.Data = zeros(dimensions, char(className));
                end
            end
        end

        function write(obj, first, chunk)
            %write Frames first..first+n-1 of the stack (1-based)
            if obj.Mode == "none"
                return
            end
            if obj.Closed
                nansen.internal.throwError("invalid-params", "the writer of %s is closed", obj.Path)
            end
            frameSize = obj.Size(1:end - 1);
            count = numel(frameSize) + 1;
            if ndims(chunk) < count && isequal(size(chunk, 1:numel(frameSize)), frameSize)
                n = 1;
            else
                n = size(chunk, count);
            end
            last = first + n - 1;
            if n == 0
                return
            end
            if ~isequal(size(chunk, 1:numel(frameSize)), frameSize) || first < 1 || last > obj.Size(end)
                nansen.internal.throwError("invalid-params", "a %s chunk at frame %d does not fit a %s stack", ...
                    mat2str(size(chunk)), first, mat2str(obj.Size))
            end
            if obj.ClassName == "logical"
                chunk = logical(chunk);
            else
                chunk = cast(chunk, char(obj.ClassName));
            end
            if obj.Mode == "memory"
                index = repmat({':'}, 1, count);
                index{count} = first:last;
                obj.Data(index{:}) = reshape(chunk, [frameSize, n]);
            else
                obj.fillTo(first);   % frames skipped are 0
                fseek(obj.Fid, obj.DataOffset + (first - 1) * obj.frameBytes(), "bof");
                obj.put(chunk);
                obj.NextFrame = max(obj.NextFrame, last + 1);
            end
            obj.Written = obj.Written + n;
        end

        function close(obj)
            if obj.Closed
                return
            end
            obj.Closed = true;
            if obj.Mode == "file"
                obj.fillTo(obj.Size(end) + 1);
                fclose(obj.Fid);
                obj.Fid = -1;
            elseif obj.Mode == "memory"
                data = obj.Data;
                obj.Data = [];
                obj.Finish(data);
            end
        end

        function delete(obj)
            if obj.Fid >= 0
                fclose(obj.Fid);   % left without close: the file is incomplete
            end
        end
    end

    methods (Access = private)
        function bytes = frameBytes(obj)
            bytes = prod(obj.Size(1:end - 1)) * nansen.StackWriter.bytesOf(obj.ClassName);
        end

        function put(obj, chunk)
            if obj.ClassName == "logical"
                fwrite(obj.Fid, uint8(chunk(:)), "uint8");
            else
                fwrite(obj.Fid, chunk(:), char(obj.ClassName));
            end
        end

        function fillTo(obj, frame)
            %fillTo Zeros for the frames from NextFrame to frame - 1, so the file has no gap
            if frame <= obj.NextFrame
                return
            end
            fseek(obj.Fid, 0, "eof");
            for start = obj.NextFrame:100:frame - 1
                n = min(100, frame - start);
                fwrite(obj.Fid, zeros(n * obj.frameBytes(), 1, "uint8"), "uint8");
            end
            obj.NextFrame = frame;
        end
    end

    methods (Static)
        function bytes = bytesOf(className)
            className = char(className);
            sizes = struct("logical", 1, "uint8", 1, "int8", 1, "uint16", 2, "int16", 2, "uint32", 4, "int32", 4, ...
                "uint64", 8, "int64", 8, "single", 4, "double", 8);
            bytes = sizes.(className);
        end
    end
end
