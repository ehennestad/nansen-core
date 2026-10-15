function out = neuropilMasks(masks, options, which)
%neuropilMasks The neuropil around ROIs, outside every ROI, as Python's nansen.frames.neuropil_masks
%
%   masks is a cell of height x width logical masks, one per ROI; the
%   neuropil of the ROIs at which (indices into masks, all by default) is
%   made, with every ROI of masks reckoned with. ophys.extractSignals's
%   neuropil, and rois.neuropil's.
%
%   neuropilMethod "ring": the pixels at square distance neuropilGap+1 ..
%   neuropilGap+neuropilWidth from the ROI. "expansion", dev's
%   (estimateNeuropilMasks): the ROI's mask dilated, alternately by its four
%   sides (even steps) and its four diagonals (odd steps), less the ROI,
%   until the part outside the ignored pixels covers neuropilExpansionFactor
%   times the ROI's area (at most the rest of the image), or after 101
%   steps; the ignored pixels (every ROI, dilated neuropilSeparation times,
%   from a diagonal step) are then taken out. Options not given take
%   ophys.extract_signals's defaults (ring, 1, 3, 4, 0).
    if nargin < 3
        which = 1:numel(masks);
    end
    out = cell(1, numel(which));
    if isempty(masks)
        return
    end
    union = false(size(masks{1}));
    for i = 1:numel(masks)
        union = union | masks{i};
    end
    if string(nansen.internal.getField(options, "neuropilMethod", "ring")) ~= "expansion"
        gap = double(nansen.internal.getField(options, "neuropilGap", 1));
        width = double(nansen.internal.getField(options, "neuropilWidth", 3));
        for k = 1:numel(which)
            mask = masks{which(k)};
            out{k} = dilateSquare(mask, gap + width) & ~dilateSquare(mask, gap) & ~union;
        end
        return
    end
    factor = double(nansen.internal.getField(options, "neuropilExpansionFactor", 4));
    ignored = union;
    for step = 1:double(nansen.internal.getField(options, "neuropilSeparation", 0))
        ignored = dilateOddEven(ignored, step);
    end
    for k = 1:numel(which)
        mask = masks{which(k)};
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
        out{k} = grown & ~ignored;
    end
end

function out = dilateSquare(mask, distance)
    % Pixels within square (Chebyshev) distance of the mask
    out = mask;
    for axis = 1:2
        grown = out;
        for step = 1:min(distance, size(out, axis) - 1)
            if axis == 1
                grown(step + 1:end, :) = grown(step + 1:end, :) | out(1:end - step, :);
                grown(1:end - step, :) = grown(1:end - step, :) | out(step + 1:end, :);
            else
                grown(:, step + 1:end) = grown(:, step + 1:end) | out(:, 1:end - step);
                grown(:, 1:end - step) = grown(:, 1:end - step) | out(:, step + 1:end);
            end
        end
        out = grown;
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
