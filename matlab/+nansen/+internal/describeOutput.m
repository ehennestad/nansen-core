function out = describeOutput(name, value, maxPoints)
%describeOutput What a preview tells of a saved value: its size and range, and an image of it where it is one
%
%   A document (struct) is kind "document", with rois (their number) for
%   ROIs; a numeric or logical array is kind "array", with size, min, max
%   and mean of its finite values (4 decimals) and, when it is at least 8 x
%   8, image (height, width, low, high, pixels of its mean over the frames,
%   as data.frame); anything else is kind "value". With maxPoints, an array
%   of one column (frames x 1) also has trace (frames, step and values, as
%   data.traces gives the column thinned to maxPoints). As Python's
%   nansen.preview.describe.
    if nargin < 3
        maxPoints = [];
    end
    if isstruct(value)
        out = struct("name", name, "kind", "document");
        if isfield(value, "rois")
            out.rois = numel(value.rois);
        end
        return
    end
    if ~(isnumeric(value) || islogical(value)) || isempty(value)
        out = struct("name", name, "kind", "value", "size", size(value));
        return
    end
    values = double(value(:));
    values = values(isfinite(values));
    rounded = @(v) floor(v * 10000 + 0.5) / 10000;
    out = struct("name", name, "kind", "array", "size", size(value), "min", NaN, "max", NaN, "mean", NaN);   % NaN is null in JSON
    if ~isempty(values)
        out.min = rounded(min(values));
        out.max = rounded(max(values));
        out.mean = rounded(mean(values));
    end
    if size(value, 1) >= 8 && size(value, 2) >= 8
        projection = "";
        if ndims(value) >= 3
            projection = "mean";
        end
        frame = nansen.internal.imageFrame(value, 0, 0, projection, []);
        out.image = struct("height", frame.height, "width", frame.width, "low", frame.low, "high", frame.high, "pixels", frame.pixels);
    end
    if ~isempty(maxPoints) && ismatrix(value) && numel(value) >= 2 && numel(value) == size(value, 1)
        traces = nansen.internal.signalTraces({char(name)}, {value}, 0, 0, [], maxPoints);
        out.trace = struct("frames", traces.frames, "step", traces.step, "values", {traces.traces{1}.columns{1}.values});
    end
end
