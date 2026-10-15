function out = describeOutput(name, value)
%describeOutput What a preview tells of a saved value: its size and range, and an image of it where it is one
%
%   A document (struct) is kind "document", with rois (their number) for
%   ROIs; a numeric or logical array is kind "array", with size, min, max
%   and mean of its finite values (4 decimals) and, when it is at least 8 x
%   8, image (height, width, low, high, pixels of its mean over the frames,
%   as data.frame); anything else is kind "value". As Python's
%   nansen.preview.describe.
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
end
