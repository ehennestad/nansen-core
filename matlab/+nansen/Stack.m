classdef Stack
%Stack An image stack read a chunk of frames at a time
%
%   A stack is height x width (x channels (x planes)) x frames, frames
%   last. stack.frames(first, last) reads frames first..last (1-based, cut
%   to the stack); stack.all() reads them all. A file adapter that can
%   gives one with open(paths), several files joined along the frames in
%   natural order, and Project.openStack gives one for any variable.
%   MaxFrames, when finite, is the most frames one read may ask for, all()
%   included: a test sets it (Project.StackFrameLimit) to show that a
%   method reads a recording in chunks and never whole. Metadata is what
%   the files tell about the recording, each field only when they give it:
%   frameRate (frames per second; volumes per second for a stack with
%   planes), pixelSize ([x, y] µm per pixel) and zStep (µm between
%   planes). Python's nansen.stacks.Stack is the same.

    properties (SetAccess = private)
        Size (1, :) double
        ClassName (1, 1) string
    end

    properties
        MaxFrames (1, 1) double = Inf
        Metadata (1, 1) struct = struct()
    end

    properties (Access = private)
        Reader   % @(first, last) the frames first..last
    end

    methods
        function obj = Stack(dimensions, className, reader)
            obj.Size = double(dimensions);
            obj.ClassName = string(className);
            obj.Reader = reader;
        end

        function n = numFrames(obj)
            n = obj.Size(end);
        end

        function data = frames(obj, first, last)
            %frames Frames first..last (1-based, cut to the stack), as an array of size [Size(1:end-1), count]
            first = max(1, double(first));
            last = min(obj.numFrames(), double(last));
            if last < first
                if obj.ClassName == "logical"
                    data = false([obj.Size(1:end - 1), 0]);
                else
                    data = zeros([obj.Size(1:end - 1), 0], char(obj.ClassName));
                end
                return
            end
            if last - first + 1 > obj.MaxFrames
                nansen.internal.throwError("invalid-params", "%d frames asked for at once; this stack gives at most %d", ...
                    last - first + 1, obj.MaxFrames)
            end
            data = obj.Reader(first, last);
            expected = [obj.Size(1:end - 1), last - first + 1];
            actual = size(data, 1:numel(expected));
            if ~isequal(actual, expected) || ndims(data) > numel(expected) && size(data, numel(expected) + 1) > 1
                nansen.internal.throwError("invalid-data", "read %s for frames %d..%d of a %s stack", ...
                    mat2str(size(data)), first, last, mat2str(obj.Size))
            end
        end

        function data = all(obj)
            %all Every frame (refused when MaxFrames is less than the frame count)
            data = obj.frames(1, obj.numFrames());
        end

        function out = select(obj, dim, index)
            %select The stack at index of dimension dim (not the frames'), that dimension dropped; still lazy
            if dim >= numel(obj.Size) || index < 1 || index > obj.Size(dim)
                nansen.internal.throwError("invalid-params", "dimension %d of a %s stack has no index %d", dim, mat2str(obj.Size), index)
            end
            dimensions = obj.Size;
            dimensions(dim) = [];
            source = obj;
            out = nansen.Stack(dimensions, obj.ClassName, @(first, last) nansen.Stack.pick(source.frames(first, last), dim, index));
            out.MaxFrames = obj.MaxFrames;
            out.Metadata = obj.Metadata;
        end

        function out = cut(obj, first, last)
            %cut Frames first..last (1-based; last Inf for the last) as a stack, still lazy: its frame 1 is frame first
            %
            %   A range that is empty or not within the stack is refused
            %   (invalid-params). As Python's Stack.cut.
            count = obj.numFrames();
            first = double(first);
            last = double(last);
            if isinf(last)
                last = count;
            end
            if first < 1 || last < first || last > count || first ~= round(first) || last ~= round(last)
                nansen.internal.throwError("invalid-params", "frames %d to %d (from 1) are not frames of a stack of %d", first, last, count)
            end
            source = obj;
            out = nansen.Stack([obj.Size(1:end - 1), last - first + 1], obj.ClassName, ...
                @(a, b) source.frames(first - 1 + a, first - 1 + b));
            out.MaxFrames = obj.MaxFrames;
            out.Metadata = obj.Metadata;
        end

        function varargout = size(obj, dim)
            dimensions = obj.Size;
            if nargin > 1
                padded = [dimensions, ones(1, max(dim) - numel(dimensions))];
                varargout = {padded(dim)};
                return
            end
            if nargout <= 1
                varargout = {dimensions};
                return
            end
            padded = [dimensions, ones(1, nargout - numel(dimensions))];
            varargout = num2cell([padded(1:nargout - 1), prod(padded(nargout:end))]);
        end

        function n = ndims(obj)
            n = numel(obj.Size);
        end
    end

    methods (Static)
        function stack = fromArray(data, count)
            %fromArray A stack over an array already at hand (a vector is a column of frames)
            %
            %   fromArray(data, count) makes it count-dimensional: MATLAB drops a
            %   last dimension of 1, so a height x width x 1 array needs count 3.
            if isscalar(data) && nargin < 2
                nansen.internal.throwError("invalid-data", "a single value is not a stack")
            end
            if nargin < 2
                if isvector(data)
                    data = reshape(data, [], 1);
                end
                count = ndims(data);
            end
            dimensions = size(data, 1:count);
            stack = nansen.Stack(dimensions, class(data), @(first, last) nansen.Stack.lastRange(data, count, first, last));
        end

        function stack = join(stacks)
            %join Stacks (a cell array) one after the other along the frames; they must agree in everything else
            %
            %   The first one's Metadata is kept.
            if isempty(stacks)
                nansen.internal.throwError("invalid-data", "no stacks to join")
            end
            for i = 1:numel(stacks)
                if ~isa(stacks{i}, "nansen.Stack")
                    stacks{i} = nansen.Stack.fromArray(stacks{i});
                end
            end
            first = stacks{1};
            if isscalar(stacks)
                stack = first;
                return
            end
            counts = zeros(1, numel(stacks));
            for i = 1:numel(stacks)
                part = stacks{i};
                if ~isequal(part.Size(1:end - 1), first.Size(1:end - 1))
                    nansen.internal.throwError("invalid-data", "the files of a recording differ in frame size: %s and %s", ...
                        mat2str(first.Size(1:end - 1)), mat2str(part.Size(1:end - 1)))
                end
                if part.ClassName ~= first.ClassName
                    nansen.internal.throwError("invalid-data", "the files of a recording differ in type: %s and %s", first.ClassName, part.ClassName)
                end
                counts(i) = part.numFrames();
            end
            offsets = [0, cumsum(counts)];
            stack = nansen.Stack([first.Size(1:end - 1), offsets(end)], first.ClassName, ...
                @(a, b) nansen.Stack.readJoined(stacks, offsets, a, b));
            stack.Metadata = first.Metadata;
        end
    end

    methods (Static, Access = private)
        function data = lastRange(data, count, first, last)
            index = repmat({':'}, 1, count);
            index{count} = first:last;
            data = data(index{:});
        end

        function data = pick(data, dim, index)
            dimensions = size(data, 1:max(ndims(data), dim + 1));
            selector = repmat({':'}, 1, numel(dimensions));
            selector{dim} = index;
            data = data(selector{:});
            dimensions(dim) = [];
            data = reshape(data, dimensions);
        end

        function data = readJoined(stacks, offsets, first, last)
            pieces = {};
            for i = 1:numel(stacks)
                low = max(first, offsets(i) + 1);
                high = min(last, offsets(i + 1));
                if low <= high
                    pieces{end + 1} = stacks{i}.frames(low - offsets(i), high - offsets(i)); %#ok<AGROW>
                end
            end
            data = cat(numel(stacks{1}.Size), pieces{:});
        end
    end
end
