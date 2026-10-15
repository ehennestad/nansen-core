function rois = uniqueRois(areas, height, width, diameter, required, most)
%uniqueRois ROIs where areas recur, as flufinder's findUniqueRoisFromComponents, deterministically (as Python's unique_rois)
%
%   areas: a cell array of N-by-2 [row, column] pixels (1-based). rois: the same, in order of detection.
    counts = zeros(height, width);
    owners = cell(height, width);
    centroids = zeros(numel(areas), 2);
    for i = 1:numel(areas)
        pixels = areas{i};
        for k = 1:size(pixels, 1)
            counts(pixels(k, 1), pixels(k, 2)) = counts(pixels(k, 1), pixels(k, 2)) + 1;
            owners{pixels(k, 1), pixels(k, 2)}(end + 1) = i;
        end
        centroids(i, :) = mean(pixels - 1, 1);   % 0-based, as Python
    end
    remaining = true(1, numel(areas));
    rois = {};
    while numel(rois) < most && any(remaining) && max(counts, [], "all") > 0
        [~, peak] = max(reshape(counts.', 1, []));   % the first largest, in row-major order
        py = floor((peak - 1) / width) + 1;
        px = mod(peak - 1, width) + 1;
        near = owners{py, px};
        near = near(remaining(near));
        if isempty(near)
            counts(py, px) = 0;
            continue
        end
        center = [ophys.internal.medianOf(centroids(near, 1)), ophys.internal.medianOf(centroids(near, 2))];
        kept = near(all(abs(centroids(near, :) - center) < 3, 2));
        if isempty(kept)   % no area near the median: the largest group of areas within 3 px of one of them
            best = [];
            for i = near
                group = near(all(abs(centroids(near, :) - centroids(i, :)) < 3, 2));
                if numel(group) > numel(best)
                    best = group;
                end
            end
            kept = best;
        end
        if numel(kept) < required
            break
        end
        image = zeros(height, width);
        for i = kept
            index = sub2ind([height, width], areas{i}(:, 1), areas{i}(:, 2));
            image(index) = image(index) + 1;
        end
        mask = ophys.internal.roiMask(image, center, diameter);
        counts = counts - image;
        counts(mask) = 0;
        remaining(kept) = false;
        [columns, rows] = find(mask.');   % row-major
        pixels = [rows, columns];
        if ~isempty(pixels) && ~any(cellfun(@(r) ophys.internal.overlapShare(pixels, r) >= 0.75, rois))
            rois{end + 1} = pixels; %#ok<AGROW>
        end
    end
end
