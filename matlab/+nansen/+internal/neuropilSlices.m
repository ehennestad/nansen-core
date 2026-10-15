function out = neuropilSlices(neuropil, mask, count)
%neuropilSlices A neuropil split in slices of about equal area around its ROI, as Python's nansen.frames.neuropil_slices
%
%   out is a cell of count height x width logical masks: dev's
%   splitNeuropilMasks (FISSA's split_npil). The angle of each neuropil
%   pixel seen from the ROI's centroid is measured from the middle of the
%   least populated of 20 equal bins of angle (the first of them, if
%   several), so a slice does not run across the neuropil's narrowest part;
%   slice k is the pixels at or below the k / count quantile of those
%   angles (linear interpolation, as numpy.percentile) and above the one
%   before. dev's port leaves out FISSA's turn of the angles to that zero,
%   which this keeps.
    count = max(1, double(count));
    if count == 1
        out = {neuropil};
        return
    end
    out = repmat({false(size(neuropil))}, 1, count);
    [rows, columns] = find(neuropil);
    [insideRows, insideColumns] = find(mask);
    if isempty(rows) || isempty(insideRows)
        return
    end
    cy = sum(insideRows - 1) / numel(insideRows);   % 0-based; whole numbers, so exact
    cx = sum(insideColumns - 1) / numel(insideColumns);
    theta = atan2(rows - 1 - cy, columns - 1 - cx);
    edges = -pi + (0:20) * (2 * pi / 20);
    bins = zeros(size(theta));   % bin k (from 0) holds edges(k + 1) <= theta < edges(k + 2)
    for k = 2:20
        bins = bins + (theta >= edges(k));
    end
    counts = zeros(1, 20);
    for k = 0:19
        counts(k + 1) = nnz(bins == k);
    end
    [~, least] = min(counts);
    turned = theta - (edges(least) + pi / 20);
    turned(turned < 0) = turned(turned < 0) + 2 * pi;
    turned = turned - pi;
    ordered = sort(turned);
    n = numel(ordered);
    bounds = zeros(1, count);
    for k = 1:count
        position = (n - 1) * k / count;
        low = floor(position);
        high = min(low + 1, n - 1);
        bounds(k) = ordered(low + 1) + (position - low) * (ordered(high + 1) - ordered(low + 1));
    end
    for k = 1:count
        if k == 1
            chosen = turned <= bounds(1);
        else
            chosen = turned > bounds(k - 1) & turned <= bounds(k);
        end
        slice = false(size(neuropil));
        slice(sub2ind(size(neuropil), rows(chosen), columns(chosen))) = true;
        out{k} = slice;
    end
end
