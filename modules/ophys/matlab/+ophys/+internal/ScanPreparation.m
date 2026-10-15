classdef ScanPreparation < handle
%ScanPreparation What is done to each chunk of frames before it is aligned, as Python's scan_preparation
%
%   The first NumFlybackLines rows are left out, the lines are destretched
%   by Plan (ophys.internal.destretchPlan) when there is one, and the lines
%   scanned back (rows 2, 4, ... of what is left; 1, 3, ... from 0) are
%   moved by the column offset between them and the lines scanned forth. With Mode
%   "constant" the offset is found once, in the first chunk; with
%   "continuous" in each chunk of frames.

    properties (SetAccess = private)
        Stack
        Flyback (1, 1) double = 0
        Mode (1, 1) string = "none"
        Most (1, 1) double = 10
        Offsets   % chunk's first frame -> offset
        Plan = []   % the stretch correction's, or none
    end

    methods
        function obj = ScanPreparation(stack, flyback, mode, most, plan)
            if ~ismember(mode, ["none", "constant", "continuous"])
                nansen.internal.throwError("invalid-options", "bidirectionalCorrection is none, constant or continuous, not '%s'", mode)
            end
            obj.Stack = stack;
            obj.Flyback = flyback;
            obj.Mode = mode;
            obj.Most = most;
            obj.Offsets = containers.Map("KeyType", "double", "ValueType", "double");
            if nargin >= 5
                obj.Plan = plan;
            end
        end

        function chunk = cut(obj, chunk)
            % the flyback rows left out, the lines destretched
            index = repmat({':'}, 1, max(3, ndims(chunk)));
            index{1} = obj.Flyback + 1:size(chunk, 1);
            chunk = chunk(index{:});
            if ~isempty(obj.Plan)
                chunk = ophys.internal.destretch(chunk, obj.Plan);
            end
        end

        function chunk = prepare(obj, chunk, first)
            chunk = obj.cut(chunk);
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
                frames = double(obj.cut(obj.Stack.frames(key, min(key + ophys.internal.chunk() - 1, obj.Stack.Size(end)))));
                obj.Offsets(key) = ophys.internal.bidirectionalOffset(mean(frames, 3), obj.Most);
            end
            k = obj.Offsets(key);
        end
    end
end
