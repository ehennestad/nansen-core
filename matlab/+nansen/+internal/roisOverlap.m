function yes = roisOverlap(a, b)
%roisOverlap Whether two ROIs overlap as dev's findOverlappingRois finds them
%
%   a and b are N-by-2 matrices of [row, column] pixels, each pixel once.
%   They overlap when their centres (the mean of their pixels) are less
%   than 10 pixels apart and they share more than 0.75 of the smaller
%   one's pixels (dev's RoI.calculateOverlap). Unlike dev, ROIs whose
%   centres coincide exactly count too: dev leaves those out to skip an ROI
%   matching itself when a set is compared with itself. As Python's
%   nansen.frames.rois_overlap, with the same comparisons, so they come out
%   alike in both.
    yes = false;
    if isempty(a) || isempty(b)
        return
    end
    a = reshape(double(a), [], 2);
    b = reshape(double(b), [], 2);
    dy = sum(a(:, 1)) / size(a, 1) - sum(b(:, 1)) / size(b, 1);
    dx = sum(a(:, 2)) / size(a, 1) - sum(b(:, 2)) / size(b, 1);
    if dy * dy + dx * dx >= 100
        return
    end
    shared = size(intersect(unique(a, "rows"), unique(b, "rows"), "rows"), 1);
    yes = 4 * shared > 3 * min(size(a, 1), size(b, 1));
end
