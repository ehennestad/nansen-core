classdef ScanPreparation < handle
%ScanPreparation What is done to each chunk of frames before it is aligned, as Python's scan_preparation
%
%   The first NumFlybackLines rows are left out, and the lines scanned back
%   (rows 2, 4, ... of what is left; 1, 3, ... from 0) are moved by the
%   column offset between them and the lines scanned forth. With Mode
%   "constant" the offset is found once, in the first chunk; with
%   "continuous" in each chunk of frames.

    properties (SetAccess = private)
        Stack
        Flyback (1, 1) double = 0
        Mode (1, 1) string = "none"
        Most (1, 1) double = 10
        Offsets   % chunk's first frame -> offset
    end

    methods
        function obj = ScanPreparation(stack, flyback, mode, most)
            if ~ismember(mode, ["none", "constant", "continuous"])
                nansen.internal.throwError("invalid-options", "bidirectionalCorrection is none, constant or continuous, not '%s'", mode)
            end
            obj.Stack = stack;
            obj.Flyback = flyback;
            obj.Mode = mode;
            obj.Most = most;
            obj.Offsets = containers.Map("KeyType", "double", "ValueType", "double");
        end

        function chunk = prepare(obj, chunk, first)
            index = repmat({':'}, 1, max(3, ndims(chunk)));
            index{1} = obj.Flyback + 1:size(chunk, 1);
            chunk = chunk(index{:});
            if obj.Mode ~= "none"
                chunk = ophys.internal.shiftAlternateRows(chunk, obj.offset(first));
            end
        end

        function k = offset(obj, first)
            key = first;
            if obj.Mode == "constant"
                key = 1;
            end
            if ~isKey(obj.Offsets, key)
                frames = double(obj.Stack.frames(key, min(key + ophys.internal.chunk() - 1, obj.Stack.Size(end))));
                frames = frames(obj.Flyback + 1:end, :, :);
                obj.Offsets(key) = ophys.internal.bidirectionalOffset(mean(frames, 3), obj.Most);
            end
            k = obj.Offsets(key);
        end
    end
end
