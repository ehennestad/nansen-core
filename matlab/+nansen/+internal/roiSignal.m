function out = roiSignal(stack, pixels, start, stop)
%roiSignal The mean of the pixels ([row, column], 0-based) in each frame of a height x width x frames stack
%
%   Read a chunk at a time: frames start..stop-1 (0-based, stop [] for the
%   last), NaN outside them, as a frames x 1 column. For the viewer's live
%   signal of an ROI being edited. Python's nansen.frames.roi_signal is the same.
    if iscell(pixels)
        pixels = cell2mat(cellfun(@(p) reshape(double(p), 1, []), reshape(pixels, [], 1), UniformOutput=false));
    end
    pixels = reshape(double(pixels), [], 2);
    [height, width, frames] = size(stack);
    if isempty(pixels) || any(pixels(:) < 0) || any(pixels(:, 1) >= height) || any(pixels(:, 2) >= width) || any(pixels(:) ~= round(pixels(:)))
        nansen.internal.throwError("invalid-params", "pixels are [row, column] pairs inside the %d x %d image", height, width)
    end
    index = unique(pixels(:, 1) + pixels(:, 2) * height + 1);   % column-major, 1-based
    start = min(max(0, double(start)), frames);
    if isempty(stop)
        stop = frames;
    else
        stop = min(max(start, double(stop)), frames);
    end
    out = nan(frames, 1);
    chunk = 100;
    for first = start:chunk:stop - 1
        last = min(first + chunk, stop);
        part = reshape(stack.frames(first + 1, last), height * width, last - first);
        out(first + 1:last) = mean(double(part(index, :)), 1)';
    end
end
