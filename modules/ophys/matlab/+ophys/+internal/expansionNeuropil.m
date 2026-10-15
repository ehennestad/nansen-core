function out = expansionNeuropil(masks, union, factor, separation)
%expansionNeuropil dev's neuropil masks (estimateNeuropilMasks), as Python's ophys_methods.expansion_neuropil
%
%   Each ROI's mask is dilated, alternately by its four sides (even steps)
%   and its four diagonals (odd steps), less the ROI, until the part outside
%   the ignored pixels covers factor times the ROI's area (at most the rest
%   of the image), or after 101 steps; the ignored pixels (every ROI,
%   dilated separation times, from a diagonal step) are then taken out.
    ignored = union;
    for step = 1:separation
        ignored = dilateOddEven(ignored, step);
    end
    out = cell(1, numel(masks));
    for i = 1:numel(masks)
        mask = masks{i};
        area = nnz(mask);
        target = min(numel(mask) - area, factor * area);
        grown = mask;
        covered = 0;
        step = 0;
        while covered < target && step <= 100
            grown = dilateOddEven(grown, step);
            grown = grown & ~mask;
            covered = nnz(grown & ~ignored);
            step = step + 1;
        end
        out{i} = grown & ~ignored;
    end
end

function out = dilateOddEven(mask, step)
    % One dilation by the four sides (step even) or the four diagonals (step odd), nothing past the edges
    if mod(step, 2) == 0
        offsets = [1, 0; -1, 0; 0, 1; 0, -1];
    else
        offsets = [1, 1; 1, -1; -1, 1; -1, -1];
    end
    [height, width] = size(mask);
    out = mask;
    for k = 1:4
        dy = offsets(k, 1);
        dx = offsets(k, 2);
        out(1 + max(dy, 0):height + min(dy, 0), 1 + max(dx, 0):width + min(dx, 0)) = ...
            out(1 + max(dy, 0):height + min(dy, 0), 1 + max(dx, 0):width + min(dx, 0)) | ...
            mask(1 + max(-dy, 0):height + min(-dy, 0), 1 + max(-dx, 0):width + min(-dx, 0));
    end
end
