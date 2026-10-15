function out = movingMean(stack, window)
%movingMean The mean over a window of frames around each frame, as movmean: floor(window/2) before
%and window - floor(window/2) - 1 after, cut at the ends (sums kept as Python keeps them)
    frames = size(stack, 3);
    sums = cat(3, zeros(size(stack, 1), size(stack, 2)), cumsum(stack, 3));
    out = zeros(size(stack));
    for t = 0:frames - 1
        first = max(0, t - floor(window / 2));
        last = min(frames, t + window - floor(window / 2));
        out(:, :, t + 1) = (sums(:, :, last + 1) - sums(:, :, first + 1)) / (last - first);
    end
end
